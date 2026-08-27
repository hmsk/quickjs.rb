# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "quickjs"
require "minitest/autorun"
require 'etc'
require_relative 'support/cpu_workload'

module QuickjsTestHelpers
  include QuickjsCpuWorkload

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
  # A whole comparison is retried rather than the trial count being raised,
  # because the two are equivalent for flake resistance but not for cost. The
  # margin on a busy runner is thinner than the paragraph above suggests: two
  # different callers have flapped on macOS at 0.811 and 0.831, once taking 4
  # of 8 jobs down while the same commit passed 8 of 8 in the sibling run, so
  # runner-wide noise rather than the code under test. Raising `trials` to
  # cover that costs every run (5 to 12 took the suite from 12s to 19s);
  # re-measuring only when a comparison misses costs nothing when it passes,
  # and a genuinely GVL-held workload still has to beat the threshold on a
  # whole fresh comparison to slip through, which it doesn't: reverting a
  # release under test fails all attempts.
  #
  # Widening the 0.8 would be the wrong lever either way. It buys false
  # passes, and a GVL-held case can measure as low as 0.83, so there is little
  # room above 0.8 before these stop detecting a lost release at all.
  def assert_run_in_parallel(trials: 5, total_iterations: 8, attempts: 3, &workload)
    skip 'requires 2+ cores' if Etc.nprocessors < 2
# The musl legs opt out, and the reason is the paragraph above rather than
# anything about musl: these measure a wall-clock ratio, and they flapped
# at 0.817 and 0.855 in the container in two of the first four runs after
# that leg was added. Locally, at two cores, alpine and glibc both pass
# three of three, so it is the runner and the container rather than the
# libc. What those legs are there to cover is stack and allocator
# behaviour; the GVL release is still asserted on eight native legs, which
# is where a lost release would show.
skip 'timing comparisons opted out here' if ENV['QUICKJS_SKIP_PARALLELISM_TIMING']

    measure = ->(&block) {
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      block.call
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    }

    workload.call(1) # warmup: load JIT / page in caches before timing

    attempts.times do |attempt|
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

      next if parallel > single * 0.8 && attempt < attempts - 1

      assert_operator parallel, :<=, single * 0.8,
        "parallel wall clock #{(parallel * 1000).round(1)}ms not ≤ 0.8 × single #{(single * 1000).round(1)}ms — work may not be releasing the GVL (#{attempt + 1} of #{attempts} attempts)"
      return
    end
  end
end

Minitest::Spec.include(QuickjsTestHelpers)
