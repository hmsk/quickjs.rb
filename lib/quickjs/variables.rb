# frozen_string_literal: true

require "json"

module Quickjs
  # Ruby values reach JS as a declaration rather than a property assignment,
  # so the caller picks the binding form and JS's own rules apply unchanged:
  # `const` is read-only and refuses redeclaration, `var` is the only form
  # that lands on `globalThis`. Nothing here invents semantics QuickJS does
  # not already have, which is what keeps a colliding `let` in user code a
  # loud SyntaxError instead of a silent shadow.
  #
  # Defined directly on VM rather than through a prepended module, since none
  # of these wrap an existing method.
  class VM
    # `$` and `_` are ordinary identifier characters in JS. Anything outside
    # this set would be concatenated straight into source we evaluate, so
    # this check is what stops a name from smuggling in arbitrary JS.
    NAME_PATTERN = /\A[A-Za-z_$][A-Za-z0-9_$]*\z/

    # The full spec list. QuickJS refuses some of these itself, but not all:
    # a declaration eval is sloppy mode, so `var static = 1` and the other
    # strict-mode-only words evaluate cleanly there. Rejecting the whole list
    # keeps the answer the same whichever word it was.
    RESERVED_WORDS = %w[
      await break case catch class const continue debugger default delete do
      else enum export extends false finally for function if implements import
      in instanceof interface let new null package private protected public
      return static super switch this throw true try typeof var void while
      with yield
    ].freeze

    private_constant :NAME_PATTERN, :RESERVED_WORDS

    def define_const(name, value)
      _define_variable(:const, name, value)
    end

    def define_let(name, value)
      _define_variable(:let, name, value)
    end

    def define_var(name, value)
      _define_variable(:var, name, value)
    end

    private

    def _define_variable(kind, name, value)
      key = _validate_variable_name(name)
      # JSMemoryUsage.malloc_limit is an int64_t, so a limit at or above 2**63
      # comes back negative. Treat anything that is not a usable size as no
      # budget rather than as a budget of minus nine quintillion.
      budget = memory_usage[:malloc_limit]
      budget = nil unless budget.is_a?(::Integer) && budget.positive?
      # The per-container check bounds the expanding case; this catches the
      # flat one, a single enormous String or a very wide container, where no
      # inner container ever crosses the line on its own.
      literal = Quickjs._within_budget(Quickjs._js_literal(value, nil, budget), budget)
      declared = (@_defined_variables ||= {})
      existing = declared[key]

      if existing.nil?
        _refuse_unusable_global(key) if kind == :var
        # The declaration is its own eval so the caller's source is never
        # rewritten. Prepending to it would shift every line number in a
        # backtrace away from the code the caller actually wrote.
        eval_code("#{kind} #{key} = #{literal};")
        declared[key] = kind
      elsif existing != kind
        raise ::ArgumentError,
          "#{key} is already defined as a #{existing}; it cannot be redefined as a #{kind}"
      elsif kind == :const
        raise ::ArgumentError,
          "#{key} is already defined as a const; a const cannot be redefined"
      else
        # Redeclaring would be a SyntaxError for `let`, so re-defining an
        # existing binding assigns to it instead. A `var` we declared
        # ourselves can have been swapped for an accessor since, so the
        # same check applies to the assignment.
        _refuse_unusable_global(key) if kind == :var
        eval_code("#{key} = #{literal};")
      end

      key
    end

    # `var` is the only form that lands on `globalThis`, so it is the only one a
    # property already sitting there can intercept. An accessor takes the value
    # in its setter and hands JS back whatever its getter likes; a non-writable
    # data property swallows the assignment silently, because a declaration eval
    # is sloppy mode. Either way the caller was told the define succeeded when it
    # did not happen.
    #
    # This refuses a global that is already unusable. It is not a security
    # boundary, and is deliberately not described as one: it asks the VM through
    # JS, and code that has already run there can replace
    # Object.getOwnPropertyDescriptor as easily as it can install the accessor. A
    # VM that has evaluated untrusted JavaScript owns its own environment, and
    # there is no way to hand a value into it unobserved. Define before running
    # code you do not control.
    def _refuse_unusable_global(key)
      state = eval_code(<<~JS)
        (() => {
          // globalThis can itself have been replaced by an earlier define_var,
          // in which case the lookup below answers for whatever took its place
          // and reports a clean global that is not there.
          if (typeof globalThis !== 'object' || globalThis === null) return 'broken';
          const d = Object.getOwnPropertyDescriptor(globalThis, #{::JSON.generate(::String.new(key.to_s))});
          if (!d) return 'absent';
          if (d.get !== undefined || d.set !== undefined) return 'accessor';
          return d.writable ? 'writable' : 'readonly';
        })()
      JS

      case state
      when 'absent', 'writable'
        nil
      when 'accessor'
        raise ::ArgumentError,
          "cannot define var #{key}: globalThis.#{key} is an accessor, so the value would go to its " \
          "setter rather than to the variable"
      when 'readonly'
        raise ::ArgumentError,
          "cannot define var #{key}: globalThis.#{key} is not writable, so the assignment would be discarded"
      else
        # The probe reads globalThis and Object, so a caller who has already
        # replaced either of those has taken the check away from itself. That
        # is reachable from Ruby alone: define_var(:globalThis, 1) makes every
        # later probe answer for a Number and report a clean global, and
        # define_var(:Object, 1) makes it throw. Refusing an answer we do not
        # recognise turns both into a refusal rather than into a define that
        # reports success it did not have.
        raise ::ArgumentError,
          "cannot define var #{key}: this VM cannot be asked about its globals, so whether the " \
          "assignment would take effect is unknown. Replacing globalThis or Object does this"
      end
    rescue Quickjs::TypeError, Quickjs::ReferenceError => e
      raise ::ArgumentError,
        "cannot define var #{key}: asking this VM about its globals failed with #{e.class}. " \
        "Replacing globalThis or Object does this"
    end

    def _validate_variable_name(name)
      unless name.is_a?(::String) || name.is_a?(::Symbol)
        raise ::TypeError, "variable's name should be a Symbol or a String, got #{name.class}"
      end

      str = name.to_s
      unless NAME_PATTERN.match?(str)
        raise ::ArgumentError, "#{str.inspect} is not a valid JavaScript identifier"
      end
      if RESERVED_WORDS.include?(str)
        raise ::ArgumentError, "#{str.inspect} is a reserved word in JavaScript"
      end

      str.to_sym
    end
  end

  # Serialized here rather than through the C converter, which falls back to
  # `#inspect` for anything it doesn't recognize and would silently turn a
  # Time into a string. Defining a variable is an input path, so an
  # unsupported value is a caller mistake worth raising on.
  def self._js_literal(value, seen = nil, budget = nil, depth = 0)
    case value
    when nil then "null"
    when true then "true"
    when false then "false"
    # Neither to_json nor to_s: both are dispatched on the caller's object, so
    # a subclass overriding either would decide what goes into the source, and
    # a gem replacing String#to_json process-wide needs no hostile value at all.
    # String.new copies the bytes without asking the object anything, and
    # JSON.generate does the escaping here, where a monkey patch cannot reach it.
    when ::String then ::JSON.generate(::String.new(value))
    when ::Integer then value.to_s
    when ::Float then _js_float_literal(value)
    when ::Symbol then _js_symbol_literal(value)
    when ::Array, ::Hash then _js_container_literal(value, seen, budget, depth)
    else
      raise ::TypeError, "#{value.class} cannot be converted to a JavaScript value"
    end
  end

  def self._js_float_literal(value)
    return "NaN" if value.nan?
    return value.positive? ? "Infinity" : "-Infinity" if value.infinite?

    value.to_s
  end

  # `Quickjs::Value::UNDEFINED` and `NAN` are plain Symbols, so they have to
  # be recognized before the generic Symbol case. Every other Symbol becomes
  # a string, matching how the C converter treats Symbols returned from a
  # `define_function` block.
  def self._js_symbol_literal(value)
    return "undefined" if value == Value::UNDEFINED
    return "NaN" if value == Value::NAN

    ::JSON.generate(::String.new(value.to_s))
  end

  # `seen` is threaded through by identity: a structure that contains itself
  # would otherwise recurse until the stack gives out. Entries are removed on
  # the way out so a value appearing twice as siblings stays legal.
  MAX_DEPTH = 1000

  def self._js_container_literal(value, seen, budget = nil, depth = 0)
    if depth >= MAX_DEPTH
      raise ::ArgumentError,
        "value nests deeper than #{MAX_DEPTH} levels; serializing it would exhaust the Ruby stack, " \
        "which raises SystemStackError rather than something a caller can rescue"
    end

    seen ||= {}
    if seen.key?(value.object_id)
      raise ::ArgumentError, "#{value.class} contains a circular reference and cannot be converted"
    end
    seen[value.object_id] = true

    begin
      parts = []
      used = 2
      if value.is_a?(::Array)
        value.each do |v|
          parts << (piece = _js_literal(v, seen, budget, depth + 1))
          used += piece.bytesize + 1
          _over_budget!(budget) if budget && used > budget
        end
        "[#{parts.join(",")}]"
      else
        value.each do |k, v|
          parts << (piece = "#{_js_object_key(k)}:#{_js_literal(v, seen, budget, depth + 1)}")
          used += piece.bytesize + 1
          _over_budget!(budget) if budget && used > budget
        end
        "{#{parts.join(",")}}"
      end
    ensure
      seen.delete(value.object_id)
    end
  end

  # A structure that reaches the same object twice is written out twice, so a
  # graph with shared branches expands rather than being shared: each level
  # that references the level below twice doubles the output, and twenty-five
  # of those is a third of a gigabyte from a handful of Ruby objects. YAML
  # aliases and Marshal round-trips produce exactly that shape without anyone
  # meaning to.
  #
  # The bound is the VM's own memory_limit rather than a number invented here.
  # A source larger than the whole JS heap budget cannot be evaluated by that
  # VM under any circumstances, so this refuses work that provably cannot
  # succeed, and the message names the option to change. It is a ceiling and
  # not a prediction: object-heavy literals cost many times their source size
  # once parsed, so a source well under the limit can still exhaust the VM.
  #
  # Counted as each element is produced rather than after a container is
  # built, which is the difference between bounding the source and bounding
  # the host. Checking a finished container still lets `map` and `join`
  # materialise the whole thing first, so a single wide container walks past
  # any budget: three hundred references to one twenty-thousand-element array
  # reached 103MB of Ruby against a 4MB limit that never fired in time. The
  # same value stops at 6MB now.
  #
  # It is still a multiple of the limit rather than the limit. Nesting builds
  # each inner literal in full before the level above can check it, so peak
  # Ruby memory measured four to eight times the limit for the doubling shape,
  # falling as the limit rises, and about one and a half times it for the wide
  # one. What it is no longer is proportional to the structure: the same value
  # with no check at all reaches a third of a gigabyte at twenty-five levels
  # and ten gigabytes at thirty.
  def self._within_budget(literal, budget)
    return literal if budget.nil? || literal.bytesize <= budget

    _over_budget!(budget)
  end

  def self._over_budget!(budget)
    raise ::ArgumentError,
      "value serializes to more than #{budget} bytes of JavaScript, which is this VM's memory_limit; " \
      "it cannot be evaluated. Shared sub-structures are written out once per occurrence, so a value " \
      "with repeated branches expands"
  end

  # JS object keys are strings regardless, so an Integer key is unambiguous.
  # Anything else would rely on `#to_s` producing something meaningful, which
  # is the silent coercion this converter exists to avoid.
  def self._js_object_key(key)
    literal = case key
              when ::String, ::Symbol, ::Integer
                # Same reason as the value: a key whose to_s answers with
                # something other than a String is refused by String.new
                # rather than written into the source.
                ::JSON.generate(::String.new(key.is_a?(::String) ? key : key.to_s))
              else
                raise ::TypeError, "#{key.class} cannot be used as a JavaScript object key"
              end

    # In an object literal `__proto__: v` sets the prototype rather than
    # defining a property, and quoting the key does not opt out of that. A Hash
    # key of that name would otherwise vanish: the entry becomes the object's
    # prototype, `Object.keys` never lists it, and the value round-trips back
    # from JS as if it had never been sent.
    #
    # That is a difference between what Ruby holds and what JS then sees, which
    # is the shape a host-side check can be walked past: a request body with a
    # nested "__proto__" passes inspection in Ruby, where it is an ordinary key
    # with a Hash under it, and arrives in JS as inherited members of the object
    # the host handed over.
    #
    # A computed key is not the special form, so this emits the property that
    # was asked for. Only this one name needs it; nothing else in an object
    # literal means anything other than itself. JS written by hand is untouched:
    # a guest writing `{__proto__: x}` still sets a prototype, as it should.
    literal == '"__proto__"' ? "[#{literal}]" : literal
  end
end
