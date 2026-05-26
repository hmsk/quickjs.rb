# quickjs.rb

A Ruby wrapper for [QuickJS](https://bellard.org/quickjs) to run JavaScript codes via Ruby with a smaller footprint.

[![Gem Version](https://img.shields.io/gem/v/quickjs?style=for-the-badge)](https://rubygems.org/gems/quickjs) [![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/hmsk/quickjs.rb/main.yml?style=for-the-badge)](https://github.com/hmsk/quickjs.rb/actions/workflows/main.yml)


## Installation

```
gem install quickjs
```

```rb
gem 'quickjs'
```

## Usage

### `Quickjs.eval_code`: Evaluate JavaScript code instantly

```rb
require 'quickjs'

Quickjs.eval_code('const fn = (n, pow) => n ** pow; fn(2,8);') # => 256
Quickjs.eval_code('const fn = (name) => `Hi, ${name}!`; fn("Itadori");') # => "Hi, Itadori!"
Quickjs.eval_code("[1,2,3]") #=> [1, 2, 3]
Quickjs.eval_code("({ a: '1', b: 1 })") #=> { 'a' => '1', 'b' => 1 }
```

<details>
<summary>Options</summary>

#### Resources

```rb
Quickjs.eval_code(code,
  memory_limit: 1024 ** 3,   # 1GB memory limit
  max_stack_size: 1024 ** 2, # 1MB max stack size
)
```

#### Filename

```rb
# Label shown in JS stack traces (default: "<code>")
Quickjs.eval_code(code, filename: 'my_script.js')
```

#### Timeout

```rb
# eval_code will be interrupted after 1 sec (default: 100 msec)
Quickjs.eval_code(code, timeout_msec: 1_000)
```

#### Features

```rb
Quickjs.eval_code(code, features: [::Quickjs::MODULE_STD, ::Quickjs::POLYFILL_FILE])
```

| Constant | Description |
|---|---|
| `MODULE_STD` | QuickJS [`std` module](https://bellard.org/quickjs/quickjs.html#std-module) |
| `MODULE_OS` | QuickJS [`os` module](https://bellard.org/quickjs/quickjs.html#os-module) |
| `FEATURE_TIMEOUT` | `setTimeout` / `setInterval` managed by CRuby |
| `POLYFILL_INTL` | Intl API (DateTimeFormat, NumberFormat, PluralRules, Locale) |
| `POLYFILL_FILE` | W3C File API (Blob and File) |
| `POLYFILL_ENCODING` | Encoding API (TextEncoder and TextDecoder) |
| `POLYFILL_URL` | URL API (URL and URLSearchParams) |
| `POLYFILL_CRYPTO` | Web Crypto API (`crypto.getRandomValues`, `crypto.randomUUID`, `crypto.subtle`); combine with `POLYFILL_ENCODING` for string↔buffer conversion |

</details>

### `Quickjs::VM`: Maintain a consistent VM/runtime

Accepts the same [options](#quickjseval_code-evaluate-javascript-code-instantly) as `Quickjs.eval_code`.

```rb
vm = Quickjs::VM.new
vm.eval_code('const a = { b: "c" };')
vm.eval_code('a.b;') #=> "c"
vm.eval_code('a.b = "d";')
vm.eval_code('a.b;') #=> "d"
```

#### `Quickjs::VM#compile`: 🚀 Cache parsed bundles as a `Quickjs::Runnable`

Parsing large JS bundles is the dominant cost of a fresh evaluation. `compile` parses once and returns a `Quickjs::Runnable` wrapping the serialized bytecode; `run(on:)` executes it on any VM of the same QuickJS build, skipping the parser. Useful when the same bundle is evaluated repeatedly across short-lived VMs (test environments, page-per-VM web emulators).

```rb
runnable = Quickjs::VM.new.compile(File.read('big_bundle.js'), filename: 'big_bundle.js')

vm = Quickjs::VM.new
runnable.run(on: vm)                                     # use the given VM (no parse cost)
runnable.run                                             # spin up a fresh VM with default options
runnable.run(on: { features: [::Quickjs::POLYFILL_INTL] }) # ad-hoc VM with options
```

`Runnable#to_s` returns the underlying bytecode as a frozen ASCII-8BIT `String`, suitable for caching to memory or disk. `Quickjs::Runnable.new(bytecode_string)` reconstructs a `Runnable` from that blob — validation happens lazily at `run` time, so a corrupt or wrong-build blob surfaces as `Quickjs::RuntimeError` when executed. The bytecode format is tied to the QuickJS build, so include the gem version in your cache key if you persist across upgrades.

#### `Quickjs::VM#call`: ⚡ Call a JS function directly with Ruby arguments

```rb
vm = Quickjs::VM.new
vm.eval_code('function add(a, b) { return a + b; }')

vm.call('add', 1, 2)           #=> 3
vm.call(:add, 1, 2)            #=> 3  (Symbol also works)

# Nested functions — preserves `this` binding
vm.eval_code('const counter = { n: 0, inc() { return ++this.n; } }')
vm.call('counter.inc')         #=> 1
vm.call('counter.inc')         #=> 2

# Keys with special characters via bracket notation
vm.eval_code("const obj = {}; obj['my-fn'] = x => x * 2;")
vm.call('obj["my-fn"]', 21)    #=> 42

# Async functions are automatically awaited
vm.eval_code('async function fetchVal() { return 42; }')
vm.call('fetchVal')            #=> 42
```

#### `Quickjs::VM#import`: 🔌 Import ESM from a source code

```rb
vm = Quickjs::VM.new

# Equivalent to `import { default: aliasedDefault, member: member } from './exports.esm.js';`
vm.import({ default: 'aliasedDefault', member: 'member' }, from: File.read('exports.esm.js'))

vm.eval_code("aliasedDefault()") #=> Exported `default` of the ESM is called
vm.eval_code("member()") #=> Exported `member` of the ESM is called

# import { member, defaultMember } from './exports.esm.js';
vm.import(['member', 'defaultMember'], from: File.read('exports.esm.js'))

# import DefaultExport from './exports.esm.js';
vm.import('DefaultExport', from: File.read('exports.esm.js'))

# import * as all from './exports.esm.js';
vm.import('* as all', from: File.read('exports.esm.js'))
```

By default each imported binding is attached to `globalThis` under its own name so later `eval_code` / `call` can see it. Pass `code_to_expose:` to replace that step with your own JS — useful for renaming, attaching the import somewhere other than `globalThis`, or skipping the global assignment entirely for side-effect-only imports.

```rb
# Rename on the way in
vm.import('Imported', from: File.read('exports.esm.js'),
          code_to_expose: 'globalThis.RenamedImported = Imported;')

vm.eval_code('RenamedImported()')   #=> calls the default export
vm.eval_code('!!globalThis.Imported') #=> false — the original name was never assigned

# Side-effect-only import: run the module body but don't expose anything
vm.import('initSomething', from: File.read('setup.esm.js'), code_to_expose: '')
```

`code_to_expose` is just a JavaScript fragment that runs after the `import` statement, with the imported binding(s) in scope under the name(s) you requested. It works with both `from:` and `filename:`.

#### `Quickjs::VM#module_loader=`: 🧩 Resolve `import` specifiers from Ruby

By default, `import` specifiers that aren't already loaded fall through to QuickJS's filesystem loader. Set a `module_loader` Proc to resolve specifiers in-memory instead — useful when the source code lives in a database, an importmap, or a virtual filesystem.

```rb
vm = Quickjs::VM.new
modules = {
  'a' => "import { b } from 'b'; export const a = () => `a-${b()}`;",
  'b' => "export const b = () => 'b-result';"
}
vm.module_loader = ->(name) { modules[name] }

vm.import(['a'], filename: 'a')
vm.eval_code('a()') #=> 'a-b-result'
```

The Proc may accept one or two arguments. Single-arity (`->(specifier) { ... }`) is the legacy shape: the Proc gets the raw import specifier and returns the source for it. Two-arity (`->(specifier, importer) { ... }`) additionally receives the file that issued the `import`, which is what you need for importmap-style scoping. Pass `nil` to clear a previously set loader.

Return value:

- A `String` — that's the source. The canonical name used for QuickJS's module cache is the specifier itself.
- A `Hash` `{ code:, as: }` — `code:` is the source, `as:` becomes the canonical name. Use this when the same specifier should resolve to different modules depending on the importer (importmap "scopes"), since QuickJS caches by canonical name and changing the canonical is what isolates the two modules.
- `nil` or `false` — raises `Quickjs::ReferenceError` on the JS side ("module not found").
- Anything else — `Quickjs::TypeError`.

Importmap scope example:

```rb
modules = {
  '/vendor/lodash.js'       => 'export default { v: "global" };',
  '/vendor/lodash-admin.js' => 'export default { v: "admin"  };',
  '/app/admin/main.js'      => "import _ from 'lodash'; export const tag = _.v;"
}

vm.module_loader = ->(specifier, importer) {
  case specifier
  when 'lodash'
    importer.start_with?('/app/admin/') \
      ? { code: modules['/vendor/lodash-admin.js'], as: '/vendor/lodash-admin.js' }
      : { code: modules['/vendor/lodash.js'],       as: '/vendor/lodash.js' }
  else
    modules[specifier]
  end
}

vm.import(['tag'], filename: '/app/admin/main.js')
vm.eval_code('tag') #=> 'admin'
```

Without `as:`, the canonical equals the raw `specifier`. That means relative imports (`./foo.js`) from different importers all share one canonical (`./foo.js`) and therefore one cached module instance — which is rarely what you want. If you support relative imports from a plain `String` return, resolve them to absolute paths yourself before returning, or use the `Hash` form with `as:` set to the resolved path. The user-facing Proc is called at most once per `(specifier, importer)` pair across the VM's lifetime; subsequent imports hit a per-VM resolution cache.

When `module_loader=` is set, pass `filename:` to `import` instead of `from:` to resolve a named specifier directly through the loader — no inline bridge source needed. Passing both `from:` and `filename:` raises `ArgumentError`.

`import` awaits the module's top-level evaluation — top-level `await`, synchronous body execution, and any chained dynamic `import()`. The call blocks until the module's settle promise resolves. A top-level throw, a failed dynamic `import()`, or a rejected top-level `await` propagates back to Ruby as the matching `Quickjs::*Error` instead of being silently dropped.

#### `Quickjs::VM#on_unhandled_rejection`: 🚨 Catch promise rejections that have no handler

Register a block to be notified when a JS Promise rejects with no `.catch` / `then(_, onRejected)` attached at the time of rejection — fire-and-forget chains, failed dynamic imports without `try`, etc.

```rb
vm = Quickjs::VM.new
vm.on_unhandled_rejection do |err|
  warn "[JS] unhandled rejection: #{err.class} #{err.message}"
end

vm.eval_code("void Promise.reject(new TypeError('drift'));")
#=> warns: [JS] unhandled rejection: Quickjs::TypeError drift
```

Calling `on_unhandled_rejection` again with a new block replaces the previously registered one (matching `on_log`).

The block receives a `Quickjs::*Error` matching the rejection reason (`Quickjs::TypeError` for `new TypeError`, etc.); non-`Error` rejections (`Promise.reject('str')`, `Promise.reject({})`) are wrapped in `Quickjs::RuntimeError`. The exception's `#backtrace` carries the JS-side stack frames (`at func (file:line:col)`) for `Error` rejections, so the rejection site shows up directly when you log or re-raise. Exceptions raised inside the block are swallowed — propagating them out would corrupt the QuickJS runtime.

The tracker fires synchronously when QuickJS first observes the rejection. A `.catch` attached later in the same tick does **not** suppress the notification, and a chain like `Promise.reject(x).then(y).then(z)` without a terminating `.catch` may emit a notification per intermediate promise. If that noise is a problem, attach handlers synchronously or dedupe by reason identity in your block. The block runs on the QuickJS stack — heavy work blocks JS execution.

#### `Quickjs::VM#define_function`: 💎 Define a global function for JS by Ruby

```rb
vm = Quickjs::VM.new
vm.define_function("greetingTo") do |arg1|
  ['Hello!', arg1].join(' ')
end

vm.eval_code("greetingTo('Rick')") #=> 'Hello! Rick'
```

Pass an `Array` as the name to register the function on an existing JS object (the last element is the method name; preceding elements are the object path):

```rb
vm = Quickjs::VM.new
vm.eval_code("const myLib = {}")
vm.define_function(["myLib", "greetingTo"]) { |name| "Hello, #{name}!" }

vm.eval_code("myLib.greetingTo('Rick')") #=> 'Hello! Rick'

# Deeply nested
vm.eval_code("const a = { b: { c: {} } }")
vm.define_function(["a", "b", "c", "double"]) { |x| x * 2 }
vm.eval_code("a.b.c.double(21)") #=> 42
```

`define_function` returns the registered name as a `Symbol` (or an `Array` of `Symbol`s for array paths).

A Ruby exception raised inside the block is catchable in JS as an `Error`, and propagates back to Ruby as the original exception type if uncaught in JS.

```rb
vm.define_function("fail") { raise IOError, "something went wrong" }

vm.eval_code('try { fail() } catch (e) { e.message }') #=> "something went wrong"
vm.eval_code("fail()") #=> raise IOError transparently
```

With `POLYFILL_FILE` enabled, a Ruby `::File` returned from the block becomes a JS `File`-compatible proxy. Passing it back to Ruby from JS returns the original `::File` object.

```rb
vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_FILE])
vm.define_function(:get_file) { File.open('report.pdf') }

vm.eval_code("get_file().name")          #=> "report.pdf"
vm.eval_code("get_file().size")          #=> Integer (byte size)
vm.eval_code("await get_file().text()") #=> file content as String
```

#### `Quickjs::VM#on_log`: 📡 Handle console logs in real time

Register a block to be called for each `console.(log|info|debug|warn|error)` call.

```rb
vm = Quickjs::VM.new
vm.on_log { |log| puts "#{log.severity}: #{log.to_s}" }

vm.eval_code('console.log("hello", 42)')
# => prints: info: hello 42

# log.severity #=> :info / :verbose / :warning / :error
# log.to_s     #=> space-joined string of all arguments
# log.raw      #=> Array of raw Ruby values
```

#### Memory management: 🔍 Inspect and control VM memory

```rb
vm = Quickjs::VM.new

vm.memory_usage
# => { malloc_size: Integer, malloc_limit: Integer, memory_used_size: Integer,
#      atom_count: Integer, str_count: Integer, obj_count: Integer,
#      prop_count: Integer, shape_count: Integer,
#      js_func_count: Integer, js_func_code_size: Integer,
#      c_func_count: Integer, array_count: Integer }

vm.gc!             # trigger a QuickJS GC cycle; returns nil

vm.memory_poisoned? #=> false (true once the VM has hit out-of-memory)
```

When the JS heap exhausts its memory limit, QuickJS enters a fragile state where further evaluation can segfault the process. `memory_poisoned?` flips to `true` after such an event, and subsequent `eval_code` / `call` calls raise `Quickjs::RuntimeError` immediately instead of risking a crash. Rescue it and recreate the VM.

```rb
vm = Quickjs::VM.new(memory_limit: 256 * 1024 * 1024)

begin
  vm.eval_code(js)
rescue Quickjs::RuntimeError => e
  raise unless vm.memory_poisoned?
  vm = Quickjs::VM.new(memory_limit: 256 * 1024 * 1024)
  retry
end
```

#### `Quickjs::VM#dispose!`: 🧹 Release the underlying C-side runtime eagerly

By default, the `JSRuntime` / `JSContext` behind a `Quickjs::VM` lives until Ruby's GC reclaims the wrapping object. Ruby's GC sizes its trigger by the Ruby-side object footprint (a few pointers) and doesn't see the C-side JS heap, so a workload that rebuilds VMs frequently — per-request, per-page-visit, throwaway pool — can let several megabytes per dead VM accumulate before a major GC fires.

`dispose!` frees the runtime immediately and marks the VM unusable:

```rb
vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_INTL])
vm.eval_code('…')
vm.dispose!           # frees JSContext + JSRuntime now
vm.disposed?          #=> true
vm.eval_code('1 + 1') # raises Quickjs::RuntimeError "VM has been disposed"
```

`dispose!` is idempotent and safe to call before letting Ruby drop the reference — the dfree handler is a no-op on an already-disposed VM. The teardown itself can take tens of milliseconds on a VM with polyfills loaded; the GVL is released during the free so other Ruby threads (e.g. a background pool builder) keep running. For fire-and-forget teardown that doesn't block the caller, wrap it in a thread:

```rb
Thread.new { vm.dispose! }
```

#### `Quickjs::VM#drain_jobs!`: Run pending JS jobs to completion

QuickJS does not automatically drain the job queue at the end of a synchronous `eval_code` / `call`. Continuations scheduled via `Promise.resolve().then(...)` or `JS_EnqueueJob` stay pending until something explicitly runs them — `await` inside JS does, but a sync return path does not.

```rb
vm = Quickjs::VM.new
vm.eval_code('globalThis.x = 0; Promise.resolve().then(() => { x = 1 }); void 0')
vm.eval_code('x')    #=> 0  (the .then() callback hasn't run yet)
vm.drain_jobs!       #=> 1  (number of jobs executed)
vm.eval_code('x')   #=> 1
```

`drain_jobs!` keeps running until the queue empties, so jobs that schedule further jobs all run in a single call. The drain is bounded by the VM's `timeout_msec`; exceeding it raises `Quickjs::InterruptedError`.

Useful when porting JS that assumed V8's implicit-drain semantics — V8 (and therefore [mini_racer](https://github.com/rubyjs/mini_racer)) flushes pending jobs at every eval boundary, so `eval_code` already sees `.then()` continuations run by the time it returns. QuickJS doesn't. Patterns like `Promise.resolve().then(() => { ... })` and Stimulus/Hotwire callbacks that assume "the next microtask tick" silently fall through unless you call `drain_jobs!` explicitly.

### Value Conversion

| JavaScript | | Ruby | Note |
|---|:---:|---|---|
| `number` (integer / float) | ↔ | `Integer` / `Float` | |
| `string` | ↔ | `String` | |
| `true` / `false` | ↔ | `true` / `false` | |
| `null` | ↔ | `nil` | |
| `Array` | ↔ | `Array` | recursively converted |
| `Object` | ↔ | `Hash` | recursively converted; keys are always `String` |
| `function` | → | `Quickjs::Function` — `.source`, `.call(*args, on:)` | |
| `undefined` | → | `Quickjs::Value::UNDEFINED` | |
| `NaN` | → | `Quickjs::Value::NAN` | |
| `Blob` | → | `Quickjs::Blob` — `.size`, `.type`, `.content` | requires `POLYFILL_FILE` |
| `File` | → | `Quickjs::File` — `.name`, `.last_modified` + Blob attrs | requires `POLYFILL_FILE` |
| `File` proxy | ← | `::File` | requires `POLYFILL_FILE`; applies to `define_function` return values |

## Acknowledgements

- [@ursm](https://github.com/ursm) — for continuous contributions improving performance and developer experience
- [@persona-id](https://github.com/persona-id) — for providing real-world use cases that shape the direction of this project

## License

- `ext/quickjsrb/quickjs`
  - [MIT License Copyright (c) 2017-2021 by Fabrice Bellard and Charlie Gordon](https://github.com/bellard/quickjs/blob/6e2e68fd0896957f92eb6c242a2e048c1ef3cae0/LICENSE).
- `ext/quickjsrb/vendor/polyfill-intl-en.min.js` ([bundled and minified from `polyfills/`](https://github.com/hmsk/quickjs.rb/tree/main/polyfills))
  - MIT License Copyright (c) 2022 FormatJS
    - [@formatjs/intl-supportedvaluesof](https://github.com/formatjs/formatjs/blob/main/packages/intl-supportedvaluesof/LICENSE.md)
  - MIT License Copyright (c) 2023 FormatJS
    - [@formatjs/intl-getcanonicallocales](https://github.com/formatjs/formatjs/blob/main/packages/intl-getcanonicallocales/LICENSE.md)
    - [@formatjs/intl-locale](https://github.com/formatjs/formatjs/blob/main/packages/intl-locale/LICENSE.md)
    - [@formatjs/intl-pluralrules](https://github.com/formatjs/formatjs/blob/main/packages/intl-pluralrules/LICENSE.md)
    - [@formatjs/intl-numberformat](https://github.com/formatjs/formatjs/blob/main/packages/intl-numberformat/LICENSE.md)
    - [@formatjs/intl-datetimeformat](https://github.com/formatjs/formatjs/blob/main/packages/intl-datetimeformat/LICENSE.md)
    - [@formatjs/ecma402-abstract](https://github.com/formatjs/formatjs/blob/main/packages/ecma402-abstract/LICENSE.md)
    - [@formatjs/fast-memoize](https://github.com/formatjs/formatjs/blob/main/packages/fast-memoize/LICENSE.md)
    - [@formatjs/intl-localematcher](https://github.com/formatjs/formatjs/blob/main/packages/intl-localematcher/LICENSE.md)
  - MIT License Copyright (c) 2026 FormatJS
    - [@formatjs/bigdecimal](https://github.com/formatjs/formatjs/blob/main/packages/bigdecimal/LICENSE.md)

Otherwise, [the MIT License, Copyright 2024 by Kengo Hamasaki](/LICENSE).
