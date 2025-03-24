# frozen_string_literal: true

require "test_helper"

class QuickjsBlockingTest < Test::Unit::TestCase
  def run_threads(&block)
    queue = Queue.new
    t1 = Thread.new(queue) {|q| 3.times { |i| q << 't1'; sleep 0.01 } }
    t2 = Thread.new(queue) {|q| block.call; q << 't2' }
    [t1, t2].each { |t| t.join }
    queue.size.times.map { queue.pop }
  end

  def assert_sleep_a_sec_within_thread(&block)
    assert_equal(run_threads(&block), %w(t1 t1 t1 t2))
  end

  def refute_sleep_a_sec_within_thread(&block)
    refute_equal(run_threads(&block), %w(t1 t1 t1 t2))
  end

  class ProcessBlocking < QuickjsBlockingTest
    setup do
      @vm = Quickjs::VM.new(timeout_msec: 1200, features: [::Quickjs::MODULE_OS])
    end
    teardown { @vm = nil }

    test 'ensure Kernel#sleep is fine' do
      assert_sleep_a_sec_within_thread do
        sleep 0.1
      end
    end

    test 'ensure Kernel#sleep via a provided function is fine' do
      @vm.define_function 'rbsleep' do |n|
        sleep n
      end

      assert_sleep_a_sec_within_thread do
        @vm.eval_code('await rbsleep(0.1);')
      end

      assert_sleep_a_sec_within_thread do
        @vm.eval_code('async function top () { await new Promise(async resolve => { rbsleep(0.1); resolve(); }); } await top();')
      end
    end

    test 'os sleep messes' do
      refute_sleep_a_sec_within_thread do
        @vm.eval_code('os.sleep(100);')
      end
    end

    test 'awaiting os.setTimeout messes' do
      refute_sleep_a_sec_within_thread do
        @vm.eval_code('await new Promise(resolve => os.setTimeout(resolve, 100));')
      end
    end

    test 'awaiting async function which wraps os.setTimeout messes' do
      refute_sleep_a_sec_within_thread do
        @vm.eval_code('async function top () { await new Promise(resolve => os.setTimeout(resolve, 100)); } await top();')
      end
    end

    test 'awaiting os.sleepAsync messes' do
      refute_sleep_a_sec_within_thread do
        @vm.eval_code('async function top () { await os.sleepAsync(100); } await top();');
      end
    end
  end
end
