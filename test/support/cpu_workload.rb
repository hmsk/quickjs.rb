# frozen_string_literal: true

# CPU-bound JS heavy enough (~10ms at the default iteration count) that
# eval time dominates threading overhead when measuring GVL-release
# parallelism. Shared between `assert_run_in_parallel` tests
# (test_helper.rb) and benchmark/threading.rb so both measure the
# identical workload — minitest-free on purpose so the benchmark can
# require it too.
module QuickjsCpuWorkload
  def cpu_workload_js(iterations: 200_000)
    <<~JS
      (() => {
        let acc = 0;
        for (let i = 0; i < #{iterations}; i++) {
          acc = (acc + Math.sqrt(i) * Math.sin(i)) % 1e9;
        }
        globalThis.workloadAcc = acc;
        return acc;
      })();
    JS
  end
  module_function :cpu_workload_js
end
