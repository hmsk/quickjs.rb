# frozen_string_literal: true

require "test_helper"

describe "awaiting a promise" do
  def never_settles
    'await new Promise(() => {})'
  end

  # The failure being guarded against holds the GVL and ignores signals, so
  # only a separate process can be killed when it comes back.
  def outcome_within(seconds = 5)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      outcome = begin
        [:returned, yield]
      rescue Exception => e
        [:raised, e.class.name, e.message]
      end
      writer.write(Marshal.dump(outcome))
      writer.close
      exit!(0)
    end
    writer.close

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until Process.wait(pid, Process::WNOHANG)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill('KILL', pid)
        Process.wait(pid)
        flunk("still running after #{seconds}s")
      end
      sleep 0.01
    end
    Marshal.load(reader.read)
  ensure
    reader&.close
  end

  def assert_unsettleable(outcome)
    _(outcome[0..1]).must_equal [:raised, 'Quickjs::InterruptedError']
    _(outcome[2]).must_match(/can never settle/)
  end

  it "raises from eval_code without waiting out the budget" do
    outcome = outcome_within(2) { Quickjs::VM.new(timeout_msec: 60_000).eval_code(never_settles) }
    assert_unsettleable(outcome)
  end

  it "raises on a VM that keeps the GVL for a bridge" do
    outcome = outcome_within do
      Quickjs::VM.new(features: [Quickjs::FEATURE_TIMEOUT]).eval_code(never_settles)
    end
    assert_unsettleable(outcome)
  end

  it "runs a pending timer before raising" do
    outcome = outcome_within do
      logs = []
      vm = Quickjs::VM.new(features: [Quickjs::FEATURE_TIMEOUT], timeout_msec: 5_000)
      vm.on_log { |log| logs << log.raw }
      begin
        vm.eval_code("setTimeout(() => console.log('fired'), 10); #{never_settles}")
      rescue Quickjs::InterruptedError
        logs.first
      end
    end
    _(outcome).must_equal [:returned, ['fired']]
  end

  it "logs the failure without a stack placeholder" do
    outcome = outcome_within do
      logs = []
      vm = Quickjs::VM.new
      vm.on_log { |log| logs << log.raw.first }
      begin
        vm.eval_code(never_settles)
      rescue Quickjs::InterruptedError
        logs
      end
    end
    _(outcome[1].size).must_equal 1
    _(outcome[1].first).must_match(/can never settle/)
    _(outcome[1].first).wont_match(/undefined/)
  end

  it "raises from VM#call" do
    outcome = outcome_within do
      vm = Quickjs::VM.new
      vm.eval_code('globalThis.stuck = async () => { await new Promise(() => {}); }; 0')
      vm.call('stuck')
    end
    assert_unsettleable(outcome)
  end

  it "raises from a compiled Runnable" do
    outcome = outcome_within do
      vm = Quickjs::VM.new
      vm.compile(never_settles).run
    end
    assert_unsettleable(outcome)
  end

  it "raises from VM#import" do
    outcome = outcome_within do
      Quickjs::VM.new.import('x', from: "#{never_settles}; export default 1;")
    end
    assert_unsettleable(outcome)
  end

  it "leaves the VM usable" do
    outcome = outcome_within do
      vm = Quickjs::VM.new
      begin
        vm.eval_code(never_settles)
      rescue Quickjs::InterruptedError
        vm.eval_code('await Promise.resolve(42)')
      end
    end
    _(outcome).must_equal [:returned, 42]
  end

  it "still settles a chain of awaits" do
    outcome = outcome_within do
      Quickjs::VM.new.eval_code('await Promise.resolve(1); await Promise.resolve(2); 3')
    end
    _(outcome).must_equal [:returned, 3]
  end

  it "still waits for an os timer that outlasts the budget" do
    outcome = outcome_within do
      vm = Quickjs::VM.new(features: [Quickjs::MODULE_OS], timeout_msec: 50)
      vm.eval_code('await new Promise(resolve => os.setTimeout(() => resolve(1), 150))')
    end
    _(outcome).must_equal [:returned, 1]
  end

  it "still waits for a setTimeout that outlasts the budget" do
    outcome = outcome_within do
      vm = Quickjs::VM.new(features: [Quickjs::FEATURE_TIMEOUT], timeout_msec: 50)
      vm.eval_code('await new Promise(resolve => setTimeout(() => resolve(1), 150))')
    end
    _(outcome).must_equal [:returned, 1]
  end

  it "raises once the last os timer has fired without settling it" do
    outcome = outcome_within do
      vm = Quickjs::VM.new(features: [Quickjs::MODULE_OS], timeout_msec: 5_000)
      vm.eval_code("os.setTimeout(() => {}, 20); #{never_settles}")
    end
    assert_unsettleable(outcome)
  end

  it "settles from a signal handler" do
    outcome = outcome_within do
      vm = Quickjs::VM.new(features: [Quickjs::MODULE_OS], timeout_msec: 3_000)
      Thread.new do
        sleep 0.05
        Process.kill('USR1', Process.pid)
      end
      vm.eval_code('await new Promise(resolve => os.signal(os.SIGUSR1, () => resolve(1)))')
    end
    _(outcome).must_equal [:returned, 1]
  end

  it "gives up on a signal at the budget without burning CPU" do
    outcome = outcome_within do
      vm = Quickjs::VM.new(features: [Quickjs::MODULE_OS], timeout_msec: 300)
      cpu_before = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      begin
        vm.eval_code('await new Promise(resolve => os.signal(os.SIGUSR1, resolve))')
      rescue Quickjs::InterruptedError => e
        [e.class.name, Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu_before]
      end
    end
    _(outcome[1][0]).must_equal 'Quickjs::InterruptedError'
    _(outcome[1][1]).must_be :<, 0.15
  end
end
