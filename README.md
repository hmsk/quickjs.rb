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
