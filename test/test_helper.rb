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
  # This used to be asserted through wall clock: run the work in one thread,
  # run the same amount split across two, and require the second at 0.8 of
  # the first. That measures the consequence rather than the property, and
  # the consequence depends on how many cores the runner has and what else is
  # using them. It flapped accordingly, at 0.811 and 0.831 on macOS and at
  # 0.817 and 0.855 in a musl container, each time on a commit that was fine,
  # and once took an unrelated pull request red. Widening the threshold was
  # never available as an answer, because a genuinely GVL-held workload can
  # measure 0.83, so there was no room between a real failure and the noise.
  #
  # A sibling thread answers the property directly. It sleeps in a loop, and
  # each time it wakes it needs the GVL back before it can do anything at
  # all. Work that holds the GVL for its duration stops it dead; work that
  # releases lets it tick throughout. Sleeping rather than spinning keeps it
  # off the cores the work under test wants, so this measures the lock and
  # not the machine.
  #
  # The block receives an iteration count and is expected to do that many
  # units of the operation under test. Each thread should create its own VM
  # internally: QuickJS records the runtime's stack bounds at construction,
  # and while #87 re-bases them onto whichever thread evaluates, a VM is
  # still one thread at a time (#86).
  TICK_SECONDS = 0.005
  MINIMUM_TICKS = 3
  # Short workloads are repeated up to this long, so the sibling always has
  # room to tick. Without it a caller whose unit of work is a few milliseconds
  # would pass or fail on timer resolution rather than on the lock.
  MEASURE_WINDOW = 0.05

  def assert_releases_gvl(iterations: 8, &workload)
    skip 'requires 2+ cores' if Etc.nprocessors < 2

    workload.call(1) # warm up: JIT, page caches, bytecode caches

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
      workload.call(iterations)
      rounds += 1
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= MEASURE_WINDOW
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    observed = ticks - before

    stop = true
    sibling.join

    opportunities = (elapsed / TICK_SECONDS).floor
    warn format('[gvl] ticks=%d of %d in %.1fms over %d round(s)', observed, opportunities, elapsed * 1000, rounds) if ENV['GVL_DEBUG']

    assert_operator observed, :>=, MINIMUM_TICKS,
      "a sibling thread ticked #{observed} times during #{(elapsed * 1000).round(1)}ms of work " \
      "with #{opportunities} chances to, so the work is holding the GVL"
  end
end

Minitest::Spec.include(QuickjsTestHelpers)
