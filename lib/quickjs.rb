# frozen_string_literal: true

require "timeout"
require_relative "quickjs/version"
require_relative "quickjs/quickjsrb"

module Quickjs
  def eval_code(code, overwrite_opts = {})
    vm = Quickjs::VM.new(**overwrite_opts)
    res = vm.eval_code(code)
    vm = nil
    res
  end
  module_function :eval_code

  def _with_timeout(msec, proc, args)
    Timeout.timeout(msec / 1_000.0) { proc.call(*args) }
  rescue Timeout::Error
    Quickjs::InterruptedError.new('Ruby runtime got timeout', nil)
  rescue => e
    e
  end
  module_function :_with_timeout

  def _build_import(imported)
    code_define_global = ->(name) { "globalThis['#{name}'] = #{name};" }
    case imported
    in String if matched = imported.match(/\* as (.+)/)
      [imported, code_define_global.call(matched[1])]
    in String
      [imported, code_define_global.call(imported)]
    in [*all] if all.all? {|e| e.is_a? String }
      [
        imported.join(', ').yield_self{|s| '{ %s }' % s },
        imported.map(&code_define_global).join("\n")
      ]
    in { ** }
      imports, aliases = imported.to_a.map do |imp|
        ["#{imp[0]} as #{imp[1]}", imp[1].to_s]
      end.transpose

      [
        imports.join(', ').yield_self{|s| '{ %s }' % s },
        aliases.map(&code_define_global).join("\n")
      ]
    else
      raise 'Unsupported importing style'
    end
  end
  module_function :_build_import
end
