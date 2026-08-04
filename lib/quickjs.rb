# frozen_string_literal: true

require "securerandom"
require "timeout"
require_relative "quickjs/version"
require_relative "quickjs/subtle_crypto"
require_relative "quickjs/crypto_key"
require_relative "quickjs/function"
require_relative "quickjs/quickjsrb"
require_relative "quickjs/runnable"
require_relative "quickjs/polyfills"
require_relative "quickjs/variables"

module Quickjs
  class Blob
    attr_reader :size, :type, :content
  end

  class File < Blob
    attr_reader :name, :last_modified
  end

  def eval_code(code, overwrite_opts = {})
    eval_opts = {}
    eval_opts[:filename] = overwrite_opts.delete(:filename) if overwrite_opts.key?(:filename)
    eval_opts[:async] = overwrite_opts.delete(:async) if overwrite_opts.key?(:async)
    vm = Quickjs::VM.new(**overwrite_opts)
    vm.eval_code(code, **eval_opts)
  ensure
    vm&.dispose!
  end
  module_function :eval_code

  def compile(source, **opts)
    compile_opts = {}
    compile_opts[:filename] = opts.delete(:filename) if opts.key?(:filename)
    vm = Quickjs::VM.new(**opts)
    vm.compile(source, **compile_opts)
  ensure
    vm&.dispose!
  end
  module_function :compile

  def _with_timeout(msec, proc, args)
    Timeout.timeout(msec / 1_000.0) { proc.call(*args) }
  rescue Timeout::Error
    raise Quickjs::InterruptedError.new('Ruby runtime got timeout', nil)
  rescue
    raise
  end
  module_function :_with_timeout

  def _with_vm(on)
    case on
    when Quickjs::VM
      yield on
    when nil
      vm = Quickjs::VM.new
      yield vm
    when Hash
      vm = Quickjs::VM.new(**on)
      yield vm
    else
      raise ArgumentError, 'on: must be a Quickjs::VM, a Hash of VM options, or nil'
    end
  ensure
    vm&.dispose!
  end
  module_function :_with_vm

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
