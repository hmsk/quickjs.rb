# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "quickjs"
require "minitest/autorun"
require 'etc'
require_relative 'support/cpu_workload'

module QuickjsTestHelpers
  include QuickjsCpuWorkload

  # Asserts the block releases the GVL while it works, which is the point of
  # the GVL release work (#56, #59, #63, #75, #76).
  #
  # This used to be asserted through wall clock: the same work in one thread
  # against two, required at 0.8. That measured a consequence of the property
  # rather than the property, and the consequence depends on the core count
  # and load of a shared runner. It flapped at 0.811 and 0.831 on macOS and
  # 0.817 and 0.855 in a musl container, each time on a commit that was fine,
  # and once took an unrelated pull request red.
  #
  # A sibling thread answers the property directly. It sleeps in a loop, and
  # each time it wakes it needs the GVL back before it can do anything. Work
  # that holds the GVL stops it dead; work that releases lets it tick.
  #
  # It is measured against a baseline rather than a fixed number, because the
  # sibling needs a core as well as the lock. A saturated runner starves it
  # even when the GVL is free: this same call has measured 9 ticks of 11
  # locally and 2 of 12 on a macOS runner, on identical work. Running a
  # deliberately GVL-held workload in the same conditions gives that number
  # something to mean. Both windows are equal so the counts compare directly.
  #
  # The block receives an iteration count and is expected to do that many
  # units of the operation under test. Each thread should create its own VM
  # internally: QuickJS records the runtime's stack bounds at construction,
  # and while #87 re-bases them onto whichever thread evaluates, a VM is
  # still one thread at a time (#86).
  TICK_SECONDS = 0.005
  MEASURE_WINDOW = 0.15
  TICK_MARGIN = 3

  Ticks = Struct.new(:count, :opportunities, :elapsed, :rounds)

  # Repeats the block until the window is full, counting how often a sleeping
  # sibling got the GVL back meanwhile. Repeating matters for callers whose
  # unit of work is a few milliseconds, which would otherwise be measured on
  # timer resolution.
  def ticks_during(iterations)
    ticks = 0
    stop = false
    sibling = Thread.new do
      until stop
        ticks += 1
        sleep TICK_SECONDS
      end
    end
    Thread.pass

    before = ticks
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rounds = 0
    loop do
      yield iterations
      rounds += 1
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= MEASURE_WINDOW
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    observed = ticks - before

    stop = true
    sibling.join

    Ticks.new(observed, (elapsed / TICK_SECONDS).floor, elapsed, rounds)
  end

  # Holds the GVL by construction: a bridge on the VM makes can_eval_gvl_free
  # refuse to release, so every eval on it runs held. Nothing here is created
  # or disposed inside the measured region, because both of those release the
  # GVL themselves and would put ticks on the baseline.
  def with_gvl_held_workload
    vm = Quickjs::VM.new(timeout_msec: 10_000)
    vm.define_function('bridge') { 1 }
    vm.eval_code(cpu_workload_js) # warm up outside the measurement
    yield ->(iterations) { iterations.times { vm.eval_code(cpu_workload_js) } }
  ensure
    vm&.dispose!
  end

  def assert_releases_gvl(iterations: 8, &workload)
    skip 'requires 2+ cores' if Etc.nprocessors < 2

    workload.call(1) # warm up: JIT, page caches, bytecode caches
    released = ticks_during(iterations) { |n| workload.call(n) }
    held = with_gvl_held_workload { |work| ticks_during(iterations) { |n| work.call(n) } }

    if ENV['GVL_DEBUG']
      warn format('[gvl] released %d/%d in %.1fms (%d rounds), held %d/%d in %.1fms',
                  released.count, released.opportunities, released.elapsed * 1000, released.rounds,
                  held.count, held.opportunities, held.elapsed * 1000)
    end

    assert_operator released.count, :>=, held.count + TICK_MARGIN,
      "a sibling thread ticked #{released.count} times in #{(released.elapsed * 1000).round(1)}ms " \
      "of this work, against #{held.count} in #{(held.elapsed * 1000).round(1)}ms of work known to " \
      "hold the GVL — this work is not releasing it either"
  end
end

Minitest::Spec.include(QuickjsTestHelpers)
