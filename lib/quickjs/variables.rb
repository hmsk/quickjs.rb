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
      literal = Quickjs._js_literal(value)
      declared = (@_defined_variables ||= {})
      existing = declared[key]

      if existing.nil?
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
        # existing binding assigns to it instead.
        eval_code("#{key} = #{literal};")
      end

      key
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
  def self._js_literal(value, seen = nil)
    case value
    when nil then "null"
    when true then "true"
    when false then "false"
    when ::String then value.to_json
    when ::Integer then value.to_s
    when ::Float then _js_float_literal(value)
    when ::Symbol then _js_symbol_literal(value)
    when ::Array, ::Hash then _js_container_literal(value, seen)
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
  def self._js_container_literal(value, seen)
    seen ||= {}
    if seen.key?(value.object_id)
      raise ::ArgumentError, "#{value.class} contains a circular reference and cannot be converted"
    end
    seen[value.object_id] = true

    begin
      if value.is_a?(::Array)
        "[#{value.map { |v| _js_literal(v, seen) }.join(",")}]"
      else
        pairs = value.map { |k, v| "#{_js_object_key(k)}:#{_js_literal(v, seen)}" }
        "{#{pairs.join(",")}}"
      end
    ensure
      seen.delete(value.object_id)
    end
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
