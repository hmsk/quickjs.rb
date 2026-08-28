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

    # Rejected here only so the failure names the offending word on the Ruby
    # side; QuickJS refuses them anyway, just less legibly.
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
      budget = memory_usage[:malloc_limit]
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
          const d = Object.getOwnPropertyDescriptor(globalThis, #{key.to_s.to_json});
          if (!d) return 'absent';
          if (d.get !== undefined || d.set !== undefined) return 'accessor';
          return d.writable ? 'writable' : 'readonly';
        })()
      JS

      case state
      when 'accessor'
        raise ::ArgumentError,
          "cannot define var #{key}: globalThis.#{key} is an accessor, so the value would go to its " \
          "setter rather than to the variable"
      when 'readonly'
        raise ::ArgumentError,
          "cannot define var #{key}: globalThis.#{key} is not writable, so the assignment would be discarded"
      end
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
  def self._js_literal(value, seen = nil, budget = nil)
    case value
    when nil then "null"
    when true then "true"
    when false then "false"
    when ::String then value.to_json
    when ::Integer then value.to_s
    when ::Float then _js_float_literal(value)
    when ::Symbol then _js_symbol_literal(value)
    when ::Array, ::Hash then _js_container_literal(value, seen, budget)
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

    value.to_s.to_json
  end

  # `seen` is threaded through by identity: a structure that contains itself
  # would otherwise recurse until the stack gives out. Entries are removed on
  # the way out so a value appearing twice as siblings stays legal.
  def self._js_container_literal(value, seen, budget = nil)
    seen ||= {}
    if seen.key?(value.object_id)
      raise ::ArgumentError, "#{value.class} contains a circular reference and cannot be converted"
    end
    seen[value.object_id] = true

    begin
      if value.is_a?(::Array)
        _within_budget("[#{value.map { |v| _js_literal(v, seen, budget) }.join(",")}]", budget)
      else
        pairs = value.map { |k, v| "#{_js_object_key(k)}:#{_js_literal(v, seen, budget)}" }
        _within_budget("{#{pairs.join(",")}}", budget)
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
  # Checked per container rather than once at the end, because the expansion
  # is bottom-up: an inner container crosses the line long before the outer
  # one exists. That makes peak Ruby memory a small multiple of the limit,
  # measured between three and four times it across limits from 4MB to
  # 128MB, and proportional to the limit rather than to the structure. The
  # same value with no check reaches a third of a gigabyte at twenty-five
  # levels and ten at thirty.
  def self._within_budget(literal, budget)
    return literal if budget.nil? || literal.bytesize <= budget

    raise ::ArgumentError,
      "value serializes to more than #{budget} bytes of JavaScript, which is this VM's memory_limit; " \
      "it cannot be evaluated. Shared sub-structures are written out once per occurrence, so a value " \
      "with repeated branches expands"
  end

  # JS object keys are strings regardless, so an Integer key is unambiguous.
  # Anything else would rely on `#to_s` producing something meaningful, which
  # is the silent coercion this converter exists to avoid.
  def self._js_object_key(key)
    case key
    when ::String, ::Symbol, ::Integer then key.to_s.to_json
    else
      raise ::TypeError, "#{key.class} cannot be used as a JavaScript object key"
    end
  end
end
