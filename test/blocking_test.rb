# frozen_string_literal: true

require "test_helper"

class QuickjsBlockingTest < Test::Unit::TestCase
  def run_threads(vm = nil, &block)
    queue = Queue.new
    t1 = Thread.new(queue) {|q| 3.times { |i| q << 't1'; sleep 0.01 } }
    t2 = Thread.new(queue) do |q|
      # Update QuickJS stack top when using VM in a different thread
      # This is critical for proper stack overflow detection on Ubuntu
      vm&.update_stack_top
      block.call
      q << 't2'
    end
    [t1, t2].each { |t| t.join }
    queue.size.times.map { queue.pop }
  end

  def assert_sleep_a_sec_within_thread(vm = nil, &block)
    assert_equal(run_threads(vm, &block), %w(t1 t1 t1 t2))
  end

  def refute_sleep_a_sec_within_thread(vm = nil, &block)
    refute_equal(run_threads(vm, &block), %w(t1 t1 t1 t2))
  end

  class ProcessBlocking < QuickjsBlockingTest
    setup do
      @vm = Quickjs::VM.new(timeout_msec: 500, features: [::Quickjs::MODULE_OS])
    end
    teardown { @vm = nil }


    test 'ensure Kernel#sleep is fine' do
      assert_sleep_a_sec_within_thread do
        sleep 0.2
      end
    end

    test 'ensure Kernel#sleep via a provided function is fine' do
      @vm.define_function 'rbsleep' do |n|
        sleep n
      end

      assert_sleep_a_sec_within_thread(@vm) do
        @vm.eval_code('await rbsleep(0.2);')
      end

      assert_sleep_a_sec_within_thread(@vm) do
        @vm.eval_code('async function top () { await new Promise(async resolve => { rbsleep(0.2); resolve(); }); } await top();')
      end
    end

    test 'os sleep messes' do
      refute_sleep_a_sec_within_thread(@vm) do
        @vm.eval_code('os.sleep(200);')
      end
    end

    test 'awaiting os.setTimeout messes' do
      refute_sleep_a_sec_within_thread(@vm) do
        @vm.eval_code('await new Promise(resolve => os.setTimeout(resolve, 200));')
      end
    end

    test 'awaiting async function which wraps os.setTimeout messes' do
      refute_sleep_a_sec_within_thread(@vm) do
        @vm.eval_code('async function top () { await new Promise(resolve => os.setTimeout(resolve, 200)); } await top();')
      end
    end

    test 'awaiting os.sleepAsync messes' do
      refute_sleep_a_sec_within_thread(@vm) do
        @vm.eval_code('async function top () { await os.sleepAsync(200); } await top();');
      end
    end
  end

  class RubyBasedTimeout < QuickjsBlockingTest
    setup do
      @vm = Quickjs::VM.new(timeout_msec: 500, features: [::Quickjs::FEATURE_TIMEOUT])
    end
    teardown { @vm = nil }

    test 'awaiting setTimeout does not block other threads' do
      assert_sleep_a_sec_within_thread(@vm) do
        @vm.eval_code('await new Promise(resolve => setTimeout(resolve, 200));')
      end
    end
  end
end
