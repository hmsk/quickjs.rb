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
      declared = (@_defined_variables ||= {})
      existing = declared[key]

      if existing.nil?
        _refuse_unusable_global(key) if kind == :var
        # The declaration is its own eval so the caller's source is never
        # rewritten. Prepending to it would shift every line number in a
        # backtrace away from the code the caller actually wrote.
        _guard_stack { _bind_declaration(kind, key, value) }
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
        _guard_stack { _bind_declaration(nil, key, value) }
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
# The value is handed to the C converter and bound to a temporary global,
# then the declaration reads it and drops it. Nothing of the value reaches
# the program text: the only thing interpolated is the name, which
# _validate_variable_name has already constrained to an identifier.
    # The value goes to the C converter as a value and is bound to a slot the
    # declaration then reads. Nothing of it reaches the program text: the only
    # thing interpolated is the name, which _validate_variable_name has already
    # constrained to an identifier. There is no literal, so there is nothing for
    # a value to escape from.
    def _bind_declaration(kind, key, value)
      Quickjs._validate_value!(value)

      slot = "__quickjsrb_bind_#{key}"
      _set_global_value(slot, value)
      # QuickJS can run out of memory while the converter is building the value and
      # report nothing: the call returns, the slot is simply not there, and the
      # declaration below then fails naming an internal name. Asking whether the
      # slot exists, rather than what it holds, turns that into a sentence about
      # the value, and keeps working for a value that is itself undefined.
      unless eval_code("#{slot.to_json} in globalThis")
        raise ::ArgumentError,
          "value could not be built inside this VM, most likely because it needs more than its memory_limit"
      end

      begin
        eval_code(kind ? "#{kind} #{key} = #{slot};" : "#{key} = #{slot};")
      ensure
        eval_code("delete globalThis.#{slot};") rescue nil
      end
    end

    # Both the validation walk and the C converter recurse, so a deep enough
    # value exhausts one stack or the other. That arrives as SystemStackError,
    # which is not a StandardError, so a caller's `rescue => e` does not catch it
    # and the thread goes down. A fixed depth limit cannot stand in for this:
    # what a structure costs depends on the stack it is walked on, and a Ruby
    # thread has a fraction of the main thread's.
    def _guard_stack
      yield
    rescue ::SystemStackError
      raise ::ArgumentError, "value nests too deeply to convert on this thread's stack"
    end

    def _refuse_unusable_global(key)
      state = eval_code(<<~JS)
        (() => {
          // globalThis can itself have been replaced by an earlier define_var,
          // in which case the lookup below answers for whatever took its place
          // and reports a clean global that is not there.
          if (typeof globalThis !== 'object' || globalThis === null) return 'broken';
          const d = Object.getOwnPropertyDescriptor(globalThis, #{key.to_s.to_json});
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

  # Checked rather than serialized. The value goes to the C converter as a
  # value, so nothing about it reaches the program text and there is no
  # literal to escape from; what is left to do here is refuse what that
  # converter would otherwise coerce, and refuse a shape it cannot walk.
  #
  # Unsupported types are the reason this exists at all. The converter falls
  # back to #inspect, which would turn a Time into its inspect string without
  # saying so, and defining is an input path where that is a mistake worth
  # hearing about rather than something to paper over.
  def self._validate_value!(value, seen = nil)
    case value
    when nil, true, false, ::String, ::Integer, ::Float, ::Symbol
      nil
    when ::Array, ::Hash
      seen ||= {}
      if seen.key?(value.object_id)
        raise ::ArgumentError, "#{value.class} contains a circular reference and cannot be converted"
      end

      # Removed on the way out, so the same object appearing twice as siblings
      # is fine and only an actual cycle is refused. The C converter has no
      # cycle detection of its own and would recurse until the stack went, so
      # this check is what stands between a self-referential Hash and a
      # process that stops.
      seen[value.object_id] = true
      begin
        if value.is_a?(::Array)
          value.each { |v| _validate_value!(v, seen) }
        else
          value.each do |k, v|
            unless k.is_a?(::String) || k.is_a?(::Symbol) || k.is_a?(::Integer)
              raise ::TypeError, "#{k.class} cannot be used as a JavaScript object key"
            end

            _validate_value!(v, seen)
          end
        end
      ensure
        seen.delete(value.object_id)
      end
    else
      raise ::TypeError, "#{value.class} cannot be converted to a JavaScript value"
    end
end
end
