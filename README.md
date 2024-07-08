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

#### Limit resources

```rb
# 1GB memory limit
Quickjs.eval_code(code, { memory_limit: 1024 ** 3 })

# 1MB max stack size
Quickjs.eval_code(code, { max_stack_size: 1024 ** 2 })
```

#### Enable built-in modules

```rb
# enable std module
# https://bellard.org/quickjs/quickjs.html#std-module
Quickjs.eval_code(code, { features: [Quickjs::MODULE_STD] })

# enable os module
# https://bellard.org/quickjs/quickjs.html#os-module
Quickjs.eval_code(code, { features: [Quickjs::MODULE_OS] })
```

### `Quickjs::VM`: Maintain a consistent VM/runtime

```rb
vm = Quickjs::VM.new
vm.eval_code('const a = { b: "c" };')
vm.eval_code('a.b;') #=> "c"
vm.eval_code('a.b = "d";')
vm.eval_code('a.b;') #=> "d"
```

#### Config VM

```rb
vm = Quickjs::VM.new(
  memory_limit: 1024 ** 3,
  max_stack_size: 1024 ** 2,
)
```

```rb
# enable std module
# https://bellard.org/quickjs/quickjs.html#std-module
vm = Quickjs::VM.new(
  features: [::Quickjs::MODULE_STD],
)

# enable os module
# https://bellard.org/quickjs/quickjs.html#os-module
vm = Quickjs::VM.new(
  features: [::Quickjs::MODULE_OS],
)
```

#### Dispose VM explicitly

```rb
vm.dispose!
```

#### Define a global function for JS

```rb
vm = Quickjs::VM.new
vm.define_function("greetingTo") do |arg1|
  ['Hello!', arg1].join(' ')
end

vm.eval_code("greetingTo('Rick')") #=> 'Hello! Rick'
```

## License

Every file in `ext/quickjsrb/quickjs` is licensed under [the MIT License Copyright 2017-2021 by Fabrice Bellard and Charlie Goron](/ext/quickjsrb/quickjs/LICENSE).
For otherwise, [the MIT License, Copyright 2024 by Kengo Hamasaki](/LICENSE).
