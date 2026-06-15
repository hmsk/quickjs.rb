# frozen_string_literal: true

require 'bundler/inline'

gemfile(true, quiet: true) do
  source 'https://rubygems.org'
  gem 'benchmark'
end

require 'etc'
require_relative '../lib/quickjs'

# CPU-bound JS workload: a tight loop with non-trivial arithmetic.
# Large enough that any GVL contention dominates over fixed overheads.
WORKLOAD = <<~JS
  (() => {
    let acc = 0;
    for (let i = 0; i < 200000; i++) {
      acc = (acc + Math.sqrt(i) * Math.sin(i)) % 1e9;
    }
    return acc;
  })();
JS

THREAD_COUNTS = [1, 2, 4, 8]
ITERATIONS_PER_THREAD = 20
TRIALS = 5

def run(thread_count, iterations_per_thread)
  threads = Array.new(thread_count) {
    Thread.new {
      vm = Quickjs::VM.new

      begin
        iterations_per_thread.times { vm.eval_code(WORKLOAD) }
      ensure
        vm.dispose!
      end
    }
  }
  threads.each(&:join)
end

def median(values)
  sorted = values.sort
  mid    = sorted.length / 2
  sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

puts "Ruby #{RUBY_VERSION} / quickjs.rb #{Quickjs::VERSION}"
puts "Workload: #{WORKLOAD.lines.count} lines of CPU-bound JS, #{ITERATIONS_PER_THREAD} iterations/thread, median of #{TRIALS} trials"
puts "Cores reported: #{Etc.nprocessors}"
puts

# Warm up: load the extension, JIT caches, etc.
run(1, 1)

label_width = 'N threads'.length

per_iter_ms_by_n = {}
Benchmark.bm(label_width) do |x|
  THREAD_COUNTS.each do |n|
    label = "#{n} threads"
    trial_per_iter_ms = []
    x.report(label) {
      TRIALS.times {
        elapsed = Benchmark.realtime { run(n, ITERATIONS_PER_THREAD) }
        trial_per_iter_ms << elapsed / (n * ITERATIONS_PER_THREAD) * 1000
      }
    }
    per_iter_ms_by_n[n] = median(trial_per_iter_ms)
  end
end

puts
puts 'Per-iteration wall-clock (lower is better; flat across thread counts ⇒ serial; halving as N doubles ⇒ parallel):'
baseline_per_iter = per_iter_ms_by_n[THREAD_COUNTS.first]
THREAD_COUNTS.each do |n|
  per_iter_ms = per_iter_ms_by_n[n]
  speedup = n == THREAD_COUNTS.first ? 'baseline' : format('%.2fx vs 1 thread', baseline_per_iter / per_iter_ms)
  puts "#{"#{n} threads".ljust(label_width)}  #{format('%6.2f', per_iter_ms)} ms/iter  (#{speedup})"
end
