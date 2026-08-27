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
runnable.run(on: { features: [::Quickjs::POLYFILL_FILE] }) # ad-hoc VM with options
```

`Runnable#to_s` returns the underlying bytecode as a frozen ASCII-8BIT `String`, suitable for caching to memory or disk. `Quickjs::Runnable.new(bytecode_string)` reconstructs a `Runnable` from that blob — validation happens lazily at `run` time, so a corrupt or wrong-build blob surfaces as `Quickjs::RuntimeError` when executed. The bytecode format is tied to the QuickJS build, so include the gem version in your cache key if you persist across upgrades.

`Quickjs.compile` is a one-shot convenience that creates and immediately disposes a throwaway VM:

```rb
runnable = Quickjs.compile(File.read('big_bundle.js'), filename: 'big_bundle.js')
runnable.run  # execute on a fresh VM, no parse cost
```

Accepts `filename:` and the same VM options as `Quickjs.eval_code` (`memory_limit:`, `timeout_msec:`, etc.) — useful when compiling large bundles that exceed the default limits.

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
- A `Hash` `{ as: }` with no `code:` — a redirect: "resolve this specifier to `as:`". No source is provided, so the target has to be a module the VM already has, whether preloaded with `preload_modules:` or loaded by an earlier import. Pointing at anything else raises `Quickjs::ReferenceError`, since there is nothing left to load.
- `nil` or `false` — raises `Quickjs::ReferenceError` on the JS side ("module not found").
- Anything else — `Quickjs::TypeError`.

```rb
# Give a preloaded module a name of your choosing, without shipping its source twice
vm = Quickjs::VM.new(preload_modules: ['/vendor/lodash.js'])
vm.module_loader = ->(specifier, _importer) {
  {as: '/vendor/lodash.js'} if specifier == 'lodash'
}
```

Watch out for one consequence: `{code: modules[specifier], as: name}` where the lookup misses is a redirect to `name` rather than a `TypeError`, so it fails later with a `ReferenceError` instead of at the point of the mistake. Return `nil` for an unknown specifier rather than a `Hash` with a missing `code:`.

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

#### `Quickjs.compile_module`: 🧊 Compile a module once and import it anywhere

`import(from: source)` reparses the module in every VM you import it into. `compile_module` parses once and returns a `Quickjs::Importable` you can import into any number of VMs, which is what `compile` does for classic scripts.

```rb
RENDERER = Quickjs.compile_module(File.read('vendor/renderer.js'), filename: 'renderer.js')

vm = Quickjs::VM.new
vm.import(['render'], from: RENDERER)   # no parse cost, on this VM or any other
vm.eval_code('render({ id: 1 })')
```

It takes the same import shapes and `code_to_expose:` as an inline source, so switching an existing `from:` a `String` to `from:` an `Importable` is the only change needed.

Hold the `Importable` wherever the JS belongs — a constant in a gem, an attribute on a service object — and import it into as many VMs as you like. Nothing about it is process-global, which matters when several libraries in one app each ship their own JS: none of them has to agree with the others about anything.

The module's name is generated, not taken from you. It is baked into the bytecode and becomes the module's identity in every VM that imports it, so generating it means two `Importable`s built independently can never collide. `filename:` only prefixes the generated name to keep stack traces readable; it is a label, not an identity. `Importable#canonical_name` returns the generated one (`renderer.js-3f9a...`), which is what a `module_loader` means by `as:`. Each VM still gets its own instance of the module with its own module-level state, and importing the same `Importable` into one VM more than once reads the bytecode only the first time.

Compilation happens eagerly, so defer it if the JS might never be used:

```rb
def self.renderer
  @renderer ||= Quickjs.compile_module(File.read('vendor/renderer.js'))
end
```

An imported module's own `import`s still resolve through `module_loader` on first use, and `module_loader` is never asked about the `Importable` itself.

**Use this when the module's name is your own business.** If JS code elsewhere in the graph needs to write `import 'lib'` and have a `module_loader` resolve it, the module needs a name everyone agrees on, which is what `register_module` below is for. Or give the generated name a friendly alias on the VMs that want one, with a [redirect](#quickjsvmmodule_loader--resolve-import-specifiers-from-ruby):

```rb
vm.import(['render'], from: RENDERER)
vm.module_loader = ->(specifier, _importer) {
  {as: RENDERER.canonical_name} if specifier == 'renderer'
}

# JS elsewhere in the graph can now write: import { render } from 'renderer'
```

#### `Quickjs.register_module`: 📦 Preload ES modules as bytecode

A module resolved through `module_loader` is parsed again by every VM that imports it. `register_module` parses it once per process and hands each VM the compiled bytecode instead, which is the same trick `compile` plays for classic scripts. On a 220KB module that takes importing from ~10.7ms to ~1.8ms per VM.

```rb
Quickjs.register_module('lib', source: File.read('lib.js'))

vm = Quickjs::VM.new(preload_modules: ['lib'])
vm.import(['call'], filename: 'lib')
vm.eval_code('call(1, 2)')
```

Registration is process-wide, `preload_modules:` is per VM. Registering only makes a module available; each VM says which ones it wants. That split is deliberate: reading a module into a VM costs about 1.26ms per 220KB whether or not it ends up being imported, so a registry that every VM read wholesale would be slower than plain source loading as soon as a VM used only part of it. It is the same reason browsers ask for `<link rel="modulepreload">` per document rather than preloading everything they know about.

`source:` also accepts a `Proc` returning a `String`, so a gem can register at `require` time without paying the file-read cost unless a VM actually preloads it:

```rb
Quickjs.register_module('lib', source: -> { File.read('lib.js') })
```

The first VM to preload a given module pays the compile cost (on a disposable VM with a generous timeout, so it doesn't consume the user VM's `timeout_msec`); later VMs reuse the cached bytecode. Each VM still gets its own instance of the module, with its own module-level state.

**`name` is the canonical name, not a label.** It is the string JS writes in its `import` statement, the name QuickJS keys its module map by, and it is baked into the compiled bytecode. If your `module_loader` resolves specifiers to absolute paths, register under the resolved path (`/vendor/lodash.js`), not the bare specifier your JS happens to write (`lodash`). A loader that maps a specifier onto a preloaded canonical via `as:` still lands on the preloaded module, so importmap-style scoping keeps working.

Relative-looking names are the one case where that bites without a loader in play. With no `module_loader` set, QuickJS's own normalization resolves `./lib.js` against the importing file before looking in the module map, so a module registered as `./lib.js` is never found and the import falls through to the filesystem loader. Register a bare or absolute name (`lib.js`, `/app/lib.js`) unless a `module_loader` is doing the normalizing.

Two consequences worth knowing:

- **A preloaded module wins over `module_loader`, which is never asked for that name.** The module is already in the VM's module map, exactly as if it had been imported earlier, so resolution finds it before any loader runs.
- **A preloaded module's own imports are not preloaded.** They resolve through `module_loader` on first import like any other specifier, so register each module you want cached. This differs from HTML's `modulepreload`, which walks the dependency graph.

Preloading a name that isn't registered raises `ArgumentError`; names must be `String`s (a `Symbol` raises `TypeError`). `Quickjs._unregister_module(name)` removes an entry, which is mostly useful for keeping tests isolated.

**Preloading grants the module to everything running in that VM**, including untrusted code reaching it with a dynamic `import()`, and whether or not your Ruby code ever imports it. `module_loader` is the authorization point, and preloading deliberately bypasses it for that name, so a loader that allows a module for some importers and denies it for others has no say over a preloaded one. If a module needs per-importer or per-scope authorization, resolve it through `module_loader` instead of preloading it, and accept the parse cost as the price of that control.

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

The block receives a `Quickjs::*Error` matching the rejection reason (`Quickjs::TypeError` for `new TypeError`, etc.); non-`Error` rejections (`Promise.reject('str')`, `Promise.reject({})`) are wrapped in `Quickjs::RuntimeError`. One exception: if reading the reason reaches one of your own bridges and that bridge raises — a `define_function` block failing inside a `get name()` on the rejected error, say — the block receives *your* exception instead, since the rejection itself was reportable and only one read of it was not. The exception's `#backtrace` carries the JS-side stack frames (`at func (file:line:col)`) for `Error` rejections, so the rejection site shows up directly when you log or re-raise. Exceptions raised inside the block are swallowed — propagating them out would corrupt the QuickJS runtime.

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

#### `Quickjs::VM#define_const` / `#define_let` / `#define_var`: 📥 Pass Ruby values into JS

Expose a Ruby value to JS without interpolating it into your source. You pick the binding form, and it behaves exactly as the matching JavaScript declaration does:

```rb
vm = Quickjs::VM.new
vm.define_const(:user, { name: 'Itadori', tags: ['strong', 'kind'] })

vm.eval_code("user.name + ': ' + user.tags.join(', ')") #=> "Itadori: strong, kind"
```

| | JS can reassign it | Redeclaring it in JS | On `globalThis` |
| --- | --- | --- | --- |
| `define_const` | no, raises `Quickjs::TypeError` | `Quickjs::SyntaxError` | no |
| `define_let` | yes | `Quickjs::SyntaxError` | no |
| `define_var` | yes | allowed | **yes** |

Reach for `define_var` when the JS you're running expects a global to already exist — a third-party bundle reading `globalThis.APP_CONFIG`, for instance. It's the only one of the three that's visible there:

```rb
vm.define_var(:APP_CONFIG, { retries: 3 })

vm.eval_code('globalThis.APP_CONFIG.retries') #=> 3
```

**Define before you run code you do not control.** `var` is the only form that lands on `globalThis`, which is what makes it useful here and also the only one an existing property can intercept. If JavaScript has already run in the VM and left an accessor or a non-writable property under that name, the assignment would go to its setter or be discarded, so `define_var` raises `ArgumentError` rather than reporting a success that did not happen.

That check reads the VM through JavaScript, so treat it as a guard against a global that is already unusable rather than as a defence: code that has run in a VM owns that VM's environment, and a value handed to it afterwards cannot be hidden from it. `define_const` and `define_let` are unaffected, since neither touches `globalThis`.

Because these are real declarations rather than property assignments, a colliding declaration in your JS is a loud error instead of a silent shadow:

```rb
vm.define_const(:user, 1)
vm.eval_code('let user = 2;') #=> raise Quickjs::SyntaxError ("redeclaration of 'user'")
```

Defining an existing `let` or `var` again assigns to it. A `const` can't be redefined, and neither can a name switch binding form:

```rb
vm.define_let(:counter, 1)
vm.define_let(:counter, 2)
vm.eval_code('counter')       #=> 2

vm.define_const(:user, 1)
vm.define_const(:user, 2)     #=> raise ArgumentError
vm.define_var(:counter, 3)    #=> raise ArgumentError (already defined as a let)
```

The name is a `String` or `Symbol` and comes back as a `Symbol`. It has to match `/\A[A-Za-z_$][A-Za-z0-9_$]*\z/` and not be a reserved word. That is narrower than JavaScript itself, which also accepts Unicode identifiers like `値`: the name is concatenated into source that gets evaluated, so the pattern is what stops one from smuggling in arbitrary JS.

Values are converted the same way as elsewhere in the gem — `Hash`, `Array`, `String`, numerics, `true`/`false`/`nil`, plus `Quickjs::Value::UNDEFINED` and `Quickjs::Value::NAN`. Anything else raises `TypeError` rather than being silently stringified:

```rb
vm.define_const(:at, Time.now) #=> raise TypeError
```

The value is a snapshot taken when you define it, not a live reference. Mutating the Ruby object afterwards won't change what JS sees. Use [`define_function`](#quickjsvmdefine_function--define-a-global-function-for-js-by-ruby) when you want JS to read the current Ruby value on every access:

```rb
config = { retries: 3 }
vm.define_function('config') { config }

config[:retries] = 5
vm.eval_code('config().retries') #=> 5
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
vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_FILE])
vm.eval_code('…')
vm.dispose!           # frees JSContext + JSRuntime now
vm.disposed?          #=> true
vm.eval_code('1 + 1') # raises Quickjs::RuntimeError "VM has been disposed"
```

`dispose!` is idempotent and safe to call before letting Ruby drop the reference — the dfree handler is a no-op on an already-disposed VM. The teardown itself can take tens of milliseconds on a VM with polyfills loaded; the GVL is released during the free so other Ruby threads (e.g. a background pool builder) keep running. For fire-and-forget teardown that doesn't block the caller, wrap it in a thread:

```rb
Thread.new { vm.dispose! }
```

Disposing a VM that is mid-evaluation on another thread would free the runtime out from under the running JS, so `dispose!` raises `ThreadError` while JS is executing on the VM (`eval_code`, `call`, `import`, `drain_jobs!`, `compile`, `Runnable#run`) — dispose after the call returns.

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

#### Threads and parallelism

`eval_code` and `Runnable#run` release Ruby's GVL while JS runs, as long as no JS→Ruby bridge is registered on the VM (no `define_function`, `module_loader`, `on_unhandled_rejection`, and none of `FEATURE_TIMEOUT` / `POLYFILL_FILE` / `POLYFILL_CRYPTO` — `console.log` is fine). Separate VMs on separate Ruby threads then evaluate genuinely in parallel on multi-core hosts — including the compile-once-run-everywhere pattern, where per-thread VMs execute the same `Runnable` concurrently. When a bridge is registered, the GVL stays held for that VM's evals and they serialize as usual.

`compile` releases the GVL for the parse regardless of what is registered on the VM — parsing to bytecode runs no JS, so no bridge can be reached and the no-bridge rule above doesn't apply to it. Serializing the result back into a Ruby String stays on the GVL, which costs about 5% of the available speedup. So a dedicated compile VM, on its own thread, parses in parallel with everything else running in the process. `compile_module` (and therefore `Quickjs.register_module` / `Quickjs.compile_module`) does not release the GVL.

The rules for sharing VMs across threads:

- **One VM, one thread at a time**, and this one is enforced. A `Quickjs::VM` is not safe for concurrent use from multiple threads — QuickJS contexts have no internal locking — so a second thread entering while another is mid-call raises `ThreadError` rather than corrupting the heap:

  ```ruby
  vm = Quickjs::VM.new
  Thread.new { vm.eval_code('while (true) {}') }
  vm.eval_code('1 + 1')
  #=> ThreadError: cannot use a Quickjs::VM from two threads at once; it is already evaluating on #<Thread:...>
  ```

  It is refusal, not serialization: nothing queues and waits. Every method that touches the runtime is covered, `gc!` and `memory_usage` included. Handing a VM off between threads (e.g. constructing it on a warmer thread and using it on another) is still fine, since ownership is only held for the duration of a call. So is a bridge re-entering its own VM — a `define_function` proc or `on_log` listener calling `eval_code` is the same thread, and is allowed.
- **The stack budget follows the evaluating thread.** QuickJS records the creating thread's stack bounds once, which used to make a handoff trip a false stack-overflow error on trivial code. The limit is now re-based on each outermost entry against the stack of the thread about to run JS, so where the VM was built no longer matters. `max_stack_size` is a ceiling rather than a guarantee: a Ruby thread's machine stack is a fraction of the main thread's, so the budget in force is whatever that thread actually has, less a margin to report the overflow with.
- **Register bridges before evaluating.** `define_function`, `module_loader=`, and `on_unhandled_rejection` raise `ThreadError` while a GVL-released eval is in flight (e.g. from inside an `on_log` listener) — the running JS was allowed to release the GVL precisely because no bridge existed when it started.
- **`MODULE_OS` caveat:** `os.signal` and `os.ttySetRaw` mutate process-wide state inside quickjs-libc, so don't call those two from VMs running concurrently on different threads. The common APIs (`os.sleep`, `os.setTimeout`, file I/O) only touch per-runtime state and are safe.

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

An object reached more than once within a single conversion becomes one Ruby object, mirroring the graph JavaScript built. Mutating one occurrence is therefore visible through the others:

```rb
result = Quickjs.eval_code('const o = {a: 1}; [o, o]')
result[0].equal?(result[1]) #=> true

result[0]['a'] = 999
result #=> [{ 'a' => 999 }, { 'a' => 999 }]
```

A cycle has no Ruby equivalent, so the reference that closes it converts to `nil`.

## Extending: registering polyfills

`Quickjs.register_polyfill(name, source:, init: nil)` adds a polyfill to a process-wide registry. Any VM constructed with `name` in its `features:` list runs the registered bundle on top of the JS runtime. Companion gems use this hook to ship additional polyfills (e.g. `Intl.Collator`, `DisplayNames`) without bundling them into the main gem.

```rb
Quickjs.register_polyfill(
  :polyfill_my_thing,
  source: File.read('vendor/my-polyfill.min.js'),
  init: 'globalThis.MyThing ||= {};'  # optional, runs before the bundle
)

vm = Quickjs::VM.new(features: [:polyfill_my_thing])
vm.eval_code('MyThing.greet("hi")')
```

`source:` also accepts a `Proc` returning a `String` — useful in companion gems that call `register_polyfill` at `require` time without paying the file-read cost unless a VM actually opts into the feature:

```rb
Quickjs.register_polyfill(
  :polyfill_my_thing,
  source: -> { File.read('vendor/my-polyfill.min.js') }
)
```

The first VM with a given polyfill pays the parse cost (the source is compiled to QuickJS bytecode on a disposable VM with a generous timeout); subsequent VMs reuse the cached bytecode. The polyfill body runs without consuming the user VM's `timeout_msec` budget — that's reserved for user code.

The polyfill's top level must settle synchronously — no top-level `await`. `VM.new(features:)` guarantees a usable polyfill on return, but loads don't drain the job queue, so nothing past the first `await` would have run by then. A polyfill left pending raises a `Quickjs::NoAwaitError`, and any top-level throw raises the matching `Quickjs::RuntimeError` subclass, both naming the feature at construction, rather than handing back a VM with the polyfill silently half-applied.

To ship JS that user code `import`s rather than globals it reaches for, see [`Quickjs.register_module`](#quickjsregister_module--preload-es-modules-as-bytecode), which follows the same registry protocol at the module layer instead of the global one.

Intl APIs (Collator, DateTimeFormat, NumberFormat, PluralRules, Locale, etc.) live in a separate companion gem: [`quickjs-polyfill-intl`](https://github.com/hmsk/quickjs-polyfill-intl). Granular, dependency-aware, opt-in per API.

## Acknowledgements

- [@ursm](https://github.com/ursm) — for continuous contributions improving performance and developer experience
- [@persona-id](https://github.com/persona-id) — for providing real-world use cases that shape the direction of this project

## License

- `ext/quickjsrb/quickjs`
  - [MIT License Copyright (c) 2017-2021 by Fabrice Bellard and Charlie Gordon](https://github.com/bellard/quickjs/blob/6e2e68fd0896957f92eb6c242a2e048c1ef3cae0/LICENSE).

Otherwise, [the MIT License, Copyright 2024 by Kengo Hamasaki](/LICENSE).
