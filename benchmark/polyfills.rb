# frozen_string_literal: true

require 'bundler/inline'

gemfile(true, quiet: true) do
  source 'https://rubygems.org'
  gem 'benchmark'
end

require_relative '../lib/quickjs'

ITERATIONS = 50

puts "Ruby #{RUBY_VERSION} / quickjs.rb #{Quickjs::VERSION}"
puts "Iterations: #{ITERATIONS}"
puts

Benchmark.bm(50) do |x|
  x.report('VM instantiation (no polyfill):') do
    ITERATIONS.times { Quickjs::VM.new }
  end

  x.report('VM instantiation (POLYFILL_INTL):') do
    ITERATIONS.times { Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL]) }
  end

  x.report('VM instantiation (POLYFILL_ENCODING):') do
    ITERATIONS.times { Quickjs::VM.new(features: [Quickjs::POLYFILL_ENCODING]) }
  end

  x.report('VM instantiation (POLYFILL_FILE):') do
    ITERATIONS.times { Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE]) }
  end

  x.report('VM instantiation (POLYFILL_URL):') do
    ITERATIONS.times { Quickjs::VM.new(features: [Quickjs::POLYFILL_URL]) }
  end

  x.report('VM instantiation (POLYFILL_CRYPTO):') do
    ITERATIONS.times { Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO]) }
  end

  x.report('VM instantiation (all polyfills):') do
    ITERATIONS.times do
      Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL, Quickjs::POLYFILL_ENCODING, Quickjs::POLYFILL_FILE, Quickjs::POLYFILL_URL, Quickjs::POLYFILL_CRYPTO])
    end
  end

  puts

  x.report('eval simple expr (no polyfill):') do
    vm = Quickjs::VM.new
    ITERATIONS.times { vm.eval_code('1 + 1') }
  end

  x.report('eval simple expr (POLYFILL_INTL):') do
    vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL])
    ITERATIONS.times { vm.eval_code('1 + 1') }
  end

  puts

  x.report('Intl.DateTimeFormat (POLYFILL_INTL):') do
    vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL])
    ITERATIONS.times do
      vm.eval_code("new Intl.DateTimeFormat('en-US').format(new Date('2024-01-15'))")
    end
  end

  x.report('Intl.NumberFormat (POLYFILL_INTL):') do
    vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL])
    ITERATIONS.times do
      vm.eval_code("new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(1234.56)")
    end
  end

  x.report('TextEncoder/Decoder (POLYFILL_ENCODING):') do
    vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_ENCODING])
    ITERATIONS.times do
      vm.eval_code("new TextEncoder().encode('hello').length")
    end
  end

  x.report('new URL() (POLYFILL_URL):') do
    vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_URL])
    ITERATIONS.times do
      vm.eval_code("new URL('https://example.com/path?q=1').hostname")
    end
  end

  x.report('crypto.getRandomValues (POLYFILL_CRYPTO):') do
    vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO])
    ITERATIONS.times do
      vm.eval_code("crypto.getRandomValues(new Uint8Array(8)).length")
    end
  end
end
