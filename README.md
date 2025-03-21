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
Quickjs.eval_code('const fn = (name) => `Hi, ${name}!`; fn("Itadori");') # => "Hi, Itadori!
Quickjs.eval_code("const isOne = (n) => 1 === n; func(1);") #=> true (TrueClass)
Quickjs.eval_code("const isOne = (n) => 1 === n; func(3);") #=> false (FalseClass)

# When code returns 'object' for `typeof`, the result is converted via JSON.stringify (JS) -> JSON.parse (Ruby)
Quickjs.eval_code("[1,2,3]") #=> [1, 2, 3] (Array)
Quickjs.eval_code("({ a: '1', b: 1 })") #=> { 'a' => '1', 'b' => 1 } (Hash)

Quickjs.eval_code("null") #=> nil
Quickjs.eval_code('const obj = {}; obj.missingKey;') # => :undefined (Quickjs::Value::Undefined)
Quickjs.eval_code("Number('whatever')") #=> :NaN (Quickjs::Value::NAN)
```

<details>
<summary>Options</summary>

#### Resources

```rb
# 1GB memory limit
Quickjs.eval_code(code, { memory_limit: 1024 ** 3 })

# 1MB max stack size
Quickjs.eval_code(code, { max_stack_size: 1024 ** 2 })
```

#### Toggle features

```rb
# Enable `std` module by quickjs: https://bellard.org/quickjs/quickjs.html#std-module
vm = Quickjs.eval_code(features: [::Quickjs::MODULE_STD])

# Enable `os` module by quickjs: https://bellard.org/quickjs/quickjs.html#os-module
vm = Quickjs.eval_code(features: [::Quickjs::MODULE_OS])

# Expose `os.setTimouet` and `os.clearTimeout` from `os` module
vm = Quickjs.eval_code(features: [::Quickjs::FEATURES_TIMEOUT])

# Inject the polyfill of Intl
vm = Quickjs.eval_code(features: [::Quickjs::POLYFILL_INTL])
```

</details>

### `Quickjs::VM`: Maintain a consistent VM/runtime

```rb
vm = Quickjs::VM.new
vm.eval_code('const a = { b: "c" };')
vm.eval_code('a.b;') #=> "c"
vm.eval_code('a.b = "d";')
vm.eval_code('a.b;') #=> "d"
```

<details>
<summary>Config VM/runtime</summary>

#### Resources

```rb
vm = Quickjs::VM.new(
  memory_limit: 1024 ** 3,
  max_stack_size: 1024 ** 2,
)
```

#### Toggle features

```rb
# Enable `std` module by quickjs: https://bellard.org/quickjs/quickjs.html#std-module
vm = Quickjs::VM.new(features: [::Quickjs::MODULE_STD])

# Enable `os` module by quickjs: https://bellard.org/quickjs/quickjs.html#os-module
vm = Quickjs::VM.new(features: [::Quickjs::MODULE_OS])

# Expose `os.setTimouet` and `os.clearTimeout` from `os` module
vm = Quickjs::VM.new(features: [::Quickjs::FEATURES_TIMEOUT])

# Inject the polyfill of Intl
vm = Quickjs::VM.new(features: [::Quickjs::POLYFILL_INTL])
```

#### VM timeout

```rb
# `eval_code` will be interrupted after 1 sec (default: 100 msec)
vm = Quickjs::VM.new(timeout_msec: 1_000)
```
</details>

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

#### `Quickjs::VM#logs`: 💾 Capture console logs

All logs by `console.(log|info|debug|warn|error)` on VM are recorded and inspectable.

```rb
vm = Quickjs::VM.new
vm.eval_code('console.log("log me", null)')

vm.logs #=> Array of Quickjs::VM::Log
vm.logs.last.severity #=> :info
vm.logs.last.to_s #=> 'log me null'
vm.logs.last.raw #=> ['log me', nil]
```

## License

- `ext/quickjsrb/quickjs`
  - [MIT License Copyright (c) 2017-2021 by Fabrice Bellard and Charlie Gordon](https://github.com/bellard/quickjs/blob/6e2e68fd0896957f92eb6c242a2e048c1ef3cae0/LICENSE).
- `ext/quickjsrb/vendor/polyfill-intl-en.min.js`
  - MIT License Copyright (c) 2023 FormatJS
    - `[@formatjs/intl-getcanonicallocales](https://github.com/formatjs/formatjs/blob/main/packages/intl-getcanonicallocales/LICENSE.md)
    - `[@formatjs/intl-locale](https://github.com/formatjs/formatjs/blob/main/packages/intl-locale/LICENSE.md)
    - `[@formatjs/intl-pluralrules](https://github.com/formatjs/formatjs/blob/main/packages/intl-pluralrules/LICENSE.md)
    - `[@formatjs/intl-numberformat](https://github.com/formatjs/formatjs/blob/main/packages/intl-numberformat/LICENSE.md)
    - `[@formatjs/intl-datetimeformat](https://github.com/formatjs/formatjs/blob/main/packages/intl-datetimeformat/LICENSE.md)
  - MIT License Copyright (c) 2025 Michael Mclaughlin
    - [decimal.js](https://www.npmjs.com/package/decimal.js)

Otherwise, [the MIT License, Copyright 2024 by Kengo Hamasaki](/LICENSE).
