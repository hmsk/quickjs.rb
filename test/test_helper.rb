# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "quickjs"
require "minitest/autorun"
require 'etc'

module QuickjsTestHelpers
  # Asserts the block runs in parallel across Ruby threads, by comparing
  # wall-clock for the same total amount of work done serially in one thread
  # vs split across two threads. If the work releases the GVL during its hot
  # section, the 2-thread run finishes in ~half the wall clock; if it holds
  # the GVL, both runs take roughly the same time (ratio ≈ 1.0 plus thread
  # overhead). The 0.8 threshold cleanly distinguishes the two: GitHub's
  # 3-core macOS runners have been observed topping out around 1.5x
  # speedup (ratio ~0.67), so demanding better than 1.25x keeps margin on
  # both sides without flapping.
  #
  # The block receives an iteration count and is expected to do that many
  # units of the operation under test (e.g. eval_code calls, VM constructions).
  # Each thread should create its own VM internally, because QuickJS records
  # the runtime's stack base at construction time — using a VM from a thread
  # other than its creator trips a (false) stack-overflow guard.
  def assert_run_in_parallel(trials: 5, total_iterations: 8, &workload)
    skip 'requires 2+ cores' if Etc.nprocessors < 2

    measure = ->(&block) {
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      block.call
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    }

    workload.call(1) # warmup: load JIT / page in caches before timing

    single = trials.times.map {
      measure.call { workload.call(total_iterations) }
    }.min

    parallel = trials.times.map {
      measure.call {
        threads = Array.new(2) {
          Thread.new { workload.call(total_iterations / 2) }
        }
        threads.each(&:join)
      }
    }.min

    assert_operator parallel, :<=, single * 0.8,
      "parallel wall clock #{(parallel * 1000).round(1)}ms not ≤ 0.8 × single #{(single * 1000).round(1)}ms — work may not be releasing the GVL"
  end

  # CPU-bound JS heavy enough (~10ms at the default iteration count) that
  # eval time dominates threading overhead in assert_run_in_parallel.
  # benchmark/threading.rb keeps its own copy of this loop — benchmarks
  # don't load minitest helpers — so retune both if the size ever changes.
  def cpu_workload_js(iterations: 200_000)
    <<~JS
      (() => {
        let acc = 0;
        for (let i = 0; i < #{iterations}; i++) {
          acc = (acc + Math.sqrt(i) * Math.sin(i)) % 1e9;
        }
        globalThis.workloadAcc = acc;
      })();
    JS
  end
end

Minitest::Spec.include(QuickjsTestHelpers)
