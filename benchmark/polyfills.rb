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

CASES = [
  ['VM instantiation (no polyfill)',    -> { Quickjs::VM.new }],
  ['VM instantiation (POLYFILL_INTL)',  -> { Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL]) }],
  ['VM instantiation (POLYFILL_ENCODING)', -> { Quickjs::VM.new(features: [Quickjs::POLYFILL_ENCODING]) }],
  ['VM instantiation (POLYFILL_FILE)',  -> { Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE]) }],
  ['VM instantiation (POLYFILL_URL)',   -> { Quickjs::VM.new(features: [Quickjs::POLYFILL_URL]) }],
  ['VM instantiation (POLYFILL_CRYPTO)', -> { Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO]) }],
  ['VM instantiation (all polyfills)',  -> { Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL, Quickjs::POLYFILL_ENCODING, Quickjs::POLYFILL_FILE, Quickjs::POLYFILL_URL, Quickjs::POLYFILL_CRYPTO]) }],
  nil,
  ['eval simple expr (no polyfill)',    -> { vm = Quickjs::VM.new;                                    -> { vm.eval_code('1 + 1') } }],
  ['eval simple expr (POLYFILL_INTL)',  -> { vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL]); -> { vm.eval_code('1 + 1') } }],
  nil,
  ['Intl.DateTimeFormat (POLYFILL_INTL)', -> { vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL]); -> { vm.eval_code("new Intl.DateTimeFormat('en-US').format(new Date('2024-01-15'))") } }],
  ['Intl.NumberFormat (POLYFILL_INTL)',   -> { vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_INTL]); -> { vm.eval_code("new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(1234.56)") } }],
  ['TextEncoder/Decoder (POLYFILL_ENCODING)', -> { vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_ENCODING]); -> { vm.eval_code("new TextEncoder().encode('hello').length") } }],
  ['new URL() (POLYFILL_URL)',            -> { vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_URL]);      -> { vm.eval_code("new URL('https://example.com/path?q=1').hostname") } }],
  ['crypto.getRandomValues (POLYFILL_CRYPTO)', -> { vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO]); -> { vm.eval_code("crypto.getRandomValues(new Uint8Array(8)).length") } }],
]

label_width = CASES.compact.map { |label, _| label.length }.max

results = {}
Benchmark.bm(label_width) do |x|
  CASES.each do |c|
    if c.nil?
      puts
      next
    end
    label, setup = c
    inner = setup.call
    callable = inner.is_a?(Proc) ? inner : setup
    results[label] = x.report(label) { ITERATIONS.times { callable.call } }
  end
end

puts
puts "#{' ' * label_width}  ms/iteration"
CASES.each do |c|
  if c.nil?
    puts
    next
  end
  label, = c
  ms = results[label].real / ITERATIONS * 1000
  puts "#{label.ljust(label_width)}  #{format('%.3f', ms)}ms"
end
