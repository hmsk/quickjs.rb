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

    # The keyword is interpolated too, and a Symbol interpolates through
    # Symbol#to_s exactly as a name would. These are ours rather than the
    # caller's, but "ours" is not the property that matters: what reaches the
    # source has to be a String that answers for itself.
    JS_KEYWORDS = { const: "const", let: "let", var: "var" }.freeze

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

    private_constant :NAME_PATTERN, :RESERVED_WORDS, :JS_KEYWORDS

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
      # The validated String itself, all the way to the interpolation. Handing
      # back a Symbol and interpolating that put a dispatch between the check
      # and the source: interpolating a Symbol calls Symbol#to_s, so the bytes
      # that were matched against the pattern were thrown away and the name was
      # asked for again afterwards. A plain String interpolates as itself.
      key = _validate_variable_name(name)
      budget = _js_source_budget
      # The per-container check bounds the expanding case; this catches the
      # flat one, a single enormous String or a very wide container, where no
      # inner container ever crosses the line on its own.
      #
      # Depth is left to the stack rather than to a constant. What a walk
      # costs depends on the stack it runs on, and a Ruby thread's is a
      # fraction of the main thread's, so the same 900 levels are fine on one
      # and fatal on the other. SystemStackError is not a StandardError
      # either, so a caller's `rescue => e` would miss it and the thread would
      # go down.
      literal =
        begin
          ValueLiteral._within_budget(ValueLiteral._js_literal(value, nil, budget), budget)
        rescue ::SystemStackError
          raise ::ArgumentError, "value nests too deeply to convert on this thread's stack"
        end

      declared = (@_defined_variables ||= {})
      existing = declared[key]

      if existing == :interrupted
        raise ::ArgumentError,
          "#{key} was left uninitialized by a declaration this VM interrupted, so the name is " \
          "unusable for the life of the VM"
      elsif existing.nil?
        _refuse_unusable_global(key) if kind == :var
        # The declaration is its own eval so the caller's source is never
        # rewritten. Prepending to it would shift every line number in a
        # backtrace away from the code the caller actually wrote.
        #
        # The registry entry goes in before the eval rather than after it.
        # Nothing can be relied on to run in between: eval_code is a C call, so
        # an exception raised at the first Ruby checkpoint after it returns
        # lands exactly in the gap between a binding the VM now has and the
        # line that would say so. Timeout and Thread#raise are held off by the
        # mask below, but a raise from a trap handler is not, and a server that
        # does `trap("TERM") { raise Shutdown }` reaches it four times in five.
        # That left the binding live and correct in JS, absent from the
        # registry, and reported as a redeclaration nobody wrote.
        #
        # Recording first inverts which way the window can be wrong. What is
        # left is a few bytecodes before the eval, where the record is ahead of
        # a declaration that never happened, and the next define assigns to the
        # name instead of declaring it. Wrong, but not permanently.
        declared[key] = kind
        begin
          ::Thread.handle_interrupt(::Exception => :never) do
            eval_code("#{JS_KEYWORDS.fetch(kind)} #{key} = #{literal};")
          end
        rescue Quickjs::InterruptedError
          # QuickJS created the binding and the interrupt landed before it was
          # initialized, so a let or const name stays in the temporal dead zone
          # for the life of the VM: reading it, assigning to it and redeclaring
          # it all raise. Nothing here can undo that, so the next define is told
          # why rather than being left to report a redeclaration.
          #
          # A var is left alone, since redeclaring one is legal JS and works.
          declared[key] = kind == :var ? :var : :interrupted
          raise
        rescue Quickjs::RuntimeError
          # The eval itself failed, so no binding was made and the name is the
          # caller's to use again. Only QuickJS errors mean that: anything else
          # arriving here came from outside and says nothing about whether the
          # declaration ran, so the entry recorded above stands.
          declared.delete(key)
          raise
        end
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
        # `void` so the statement has no completion value. An assignment
        # expression evaluates to what was assigned, and eval_code converts
        # whatever the statement produced back into Ruby, so redefining a value
        # built a whole Ruby object graph from the JavaScript it had just
        # written and dropped it. A 200k-row Hash cost 1.6 million objects that
        # nothing read. A declaration never had this, since declarations have
        # no completion value.
        eval_code("void (#{key} = #{literal});")
      end

      # Only here, where a patched String#to_sym can decide nothing except what
      # the caller is handed back.
      key.to_sym
    end

    # memory_usage walks the whole JS heap, and the limit it reports is fixed
    # when the VM is built, so reading it per call made every define cost a
    # heap walk: 8us on an empty VM against 1.5ms on one holding a few hundred
    # thousand objects.
    #
    # JSMemoryUsage.malloc_limit is an int64_t, so a limit at or above 2**63
    # comes back negative. Anything that is not a usable size means no budget,
    # rather than a budget of minus nine quintillion.
    def _js_source_budget
      return @_js_source_budget if defined?(@_js_source_budget)

      limit = memory_usage[:malloc_limit]
      @_js_source_budget = limit.is_a?(::Integer) && limit.positive? ? limit : nil
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
          const d = Object.getOwnPropertyDescriptor(globalThis, #{::JSON.generate(::String.new(key))});
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
      # `===` rather than `name.is_a?`, which the object answers for itself.
      unless ::String === name || ::Symbol === name
        raise ::TypeError, "variable's name should be a Symbol or a String, got #{name.class}"
      end

      # A copy of the bytes, for the same reason the value path takes one.
      # `to_s` and `to_sym` are both dispatched on the caller's object, so a
      # String subclass could satisfy the pattern below with one and hand a
      # different name to the interpolation with the other. Everything after
      # this line works on a plain String that answers only for itself.
      str = ::String === name ? ::String.new(name) : ::String.new(name.to_s)
      unless NAME_PATTERN.match?(str)
        raise ::ArgumentError, "#{str.inspect} is not a valid JavaScript identifier"
      end
      if RESERVED_WORDS.include?(str)
        raise ::ArgumentError, "#{str.inspect} is a reserved word in JavaScript"
      end

      str
    end
  end

  # These build the JavaScript source for a value. They are an implementation
  # detail of the define_* methods and not something to call directly, so they
  # live behind a private constant rather than sitting on Quickjs itself.
  module ValueLiteral

    # Serialized here rather than through the C converter, which falls back to
    # `#inspect` for anything it doesn't recognize and would silently turn a
    # Time into a string. Defining a variable is an input path, so an
    # unsupported value is a caller mistake worth raising on.
    def self._js_literal(value, seen = nil, budget = nil)
      case value
      when nil then "null"
      when true then "true"
      when false then "false"
      # Neither to_json nor to_s: both are dispatched on the caller's object, so
      # a subclass overriding either would decide what goes into the source, and
      # a gem replacing String#to_json process-wide needs no hostile value at all.
      # String.new copies the bytes without asking the object anything, and
      # JSON.generate does the escaping. That is not out of a monkey patch's
      # reach, and nothing in Ruby is: JSON.generate, String#initialize,
      # Array#join and format are all replaceable, and a process that has done
      # that has bigger problems than this method. What holds is narrower and
      # is the part that matters: no method dispatched on the caller's value
      # decides these bytes.
      when ::String then _js_string_literal(value, budget)
      when ::Integer then _js_integer_literal(value, budget)
      when ::Float then _js_float_literal(value)
      when ::Symbol then _js_symbol_literal(value, budget)
      when ::Array, ::Hash then _js_container_literal(value, seen, budget)
      else
        raise ::TypeError, "#{value.class} cannot be converted to a JavaScript value"
      end
    end

    # Measured before the copy rather than after the literal exists. The
    # per-container check bounds a structure that expands as it nests, but a
    # single enormous String is one value, so nothing checked it until it had
    # been copied once and escaped once. A caller holding 300MB got 900MB.
    #
    # bytesize through an unbound method, since a subclass answering that one
    # low is exactly how a value would get past a cheap check into an
    # expensive copy.
    BYTESIZE = ::String.instance_method(:bytesize)

    # The same move for the two numeric conversions. format looked like it read
    # the number rather than asking it, but Kernel#format is itself replaceable
    # and fails open when it is: it answers with whatever the patch returns and
    # that goes straight into the source. An unbound Integer#to_s and Float#to_s
    # cannot be redirected after they are taken here, and they write the
    # shortest form that reads back as the same number rather than the widest.
    INTEGER_TO_S = ::Integer.instance_method(:to_s)
    BIT_LENGTH = ::Integer.instance_method(:bit_length)
    FLOAT_TO_S = ::Float.instance_method(:to_s)

    def self._js_string_literal(value, budget)
      _over_budget!(budget) if budget && BYTESIZE.bind_call(value) > budget

      ::JSON.generate(::String.new(value))
    end

    # A bignum costs its digits to render, and it takes more than four bits to
    # carry a decimal digit, so anything past four times the budget in bits
    # cannot come in under it. Deliberately loose: this refuses only what is
    # certainly too large, and the finished literal is measured as before.
    def self._js_integer_literal(value, budget)
      _over_budget!(budget) if budget && BIT_LENGTH.bind_call(value) / 4 > budget

      INTEGER_TO_S.bind_call(value)
    end

    # nan?, infinite? and positive? were each dispatched on the caller's Float
    # to pick between three fixed strings, which is a branch the value decided.
    # They were also unnecessary: Float#to_s already spells those three exactly
    # as JavaScript does.
    def self._js_float_literal(value)
      FLOAT_TO_S.bind_call(value)
    end

    # `Quickjs::Value::UNDEFINED` and `NAN` are plain Symbols, so they have to
    # be recognized before the generic Symbol case. Every other Symbol becomes
    # a string, matching how the C converter treats Symbols returned from a
    # `define_function` block.
    JS_SPELLED_SYMBOLS = { Value::UNDEFINED => "undefined", Value::NAN => "NaN" }
                          .compare_by_identity.freeze

    def self._js_symbol_literal(value, budget = nil)
      # Looked up by identity rather than compared with ==, which a Symbol
      # answers for itself and could use to make any Symbol undefined.
      spelled = JS_SPELLED_SYMBOLS[value]
      return spelled if spelled

      # A Symbol has no bytes to measure until to_s makes some, so the copy is
      # unavoidable. Measuring it before escaping still skips the expensive
      # half, since escaping walks and rewrites every byte.
      copy = ::String.new(value.to_s)
      _over_budget!(budget) if budget && copy.bytesize > budget

      ::JSON.generate(copy)
    end

    # `seen` is threaded through by identity: a structure that contains itself
    # would otherwise recurse until the stack gives out. Entries are removed on
    # the way out so a value appearing twice as siblings stays legal.
    #
    # compare_by_identity rather than keying on value.object_id, which the
    # value answers for itself. A Hash subclass returning a constant object_id
    # had every nested instance of it called circular; one returning a fresh
    # id each time was never seen twice and walked until the stack guard
    # caught it.
    def self._js_container_literal(value, seen, budget = nil)
      seen ||= {}.compare_by_identity
      if seen.key?(value)
        raise ::ArgumentError, "#{value.class} contains a circular reference and cannot be converted"
      end
      seen[value] = true

      begin
        # Appended to one String rather than collected and joined. The pieces
        # were retained until the end, and a Ruby String costs about forty
        # bytes of object for the two bytes of budget a small element spends,
        # so a wide container of tiny values reached twenty-seven times
        # memory_limit in host memory before the check fired. Appending keeps
        # one piece alive at a time.
        used = 2
        separator = ""
        if ::Array === value
          out = +"["
          value.each do |v|
            piece = _js_literal(v, seen, budget)
            out << separator << piece
            separator = ","
            used += piece.bytesize + 1
            _over_budget!(budget) if budget && used > budget
          end
          out << "]"
        else
          out = +"{"
          value.each do |k, v|
            piece = "#{_js_object_key(k, budget)}:#{_js_literal(v, seen, budget)}"
            out << separator << piece
            separator = ","
            used += piece.bytesize + 1
            _over_budget!(budget) if budget && used > budget
          end
          out << "}"
        end
      ensure
        seen.delete(value)
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
    # reached 103MB of Ruby against a 4MB limit that never fired in time.
    #
    # It is still a multiple of the limit rather than the limit. Nesting builds
    # each inner literal in full before the level above can check it, so the
    # doubling shape measured about eight times a 4MB limit and four and a half
    # times a 32MB one, falling as the limit rises, against twice the limit for
    # the wide shape above. Numbers from this machine, and the two that were
    # quoted here before both went stale, so treat them as an order of
    # magnitude rather than a promise. What it is no longer is proportional to
    # the structure: the same value with no check at all reaches a third of a
    # gigabyte at twenty-five levels and ten gigabytes at thirty.
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
    # `budget` for the same reason the value path takes one: a key is a value
    # the caller supplies, and it was being copied and escaped before anything
    # looked at its size. A 300MB String cost nothing as a value and 900MB as a
    # key.
    def self._js_object_key(key, budget = nil)
      literal = case key
                when ::String
                  _over_budget!(budget) if budget && BYTESIZE.bind_call(key) > budget
                  ::JSON.generate(::String.new(key))
                when ::Integer
                  # Read, not asked to describe itself, as on the value path.
                  _over_budget!(budget) if budget && BIT_LENGTH.bind_call(key) / 4 > budget
                  ::JSON.generate(INTEGER_TO_S.bind_call(key))
                when ::Symbol
                  # A Symbol has no bytes to copy, so this one asks. What it
                  # answers is still escaped here, so the worst a patched
                  # Symbol#to_s buys is a different key, not a different
                  # meaning.
                  copy = ::String.new(key.to_s)
                  _over_budget!(budget) if budget && copy.bytesize > budget
                  ::JSON.generate(copy)
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
  private_constant :ValueLiteral
end
