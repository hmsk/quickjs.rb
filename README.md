# quickjs.rb

A Ruby wrapper for [QuickJS](https://bellard.org/quickjs) to run JavaScript codes via Ruby with a smaller footprint.

![Gem Version](https://img.shields.io/gem/v/quickjs?style=for-the-badge)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/hmsk/quickjs.rb/main?style=for-the-badge)


## Installation

```
gem install quickjs
```

```rb
gem 'quickjs'
```

## Usage

### `Quickjs.evalCode`: Evaluate JavaScript code

```rb
require 'quickjs'

Quickjs.evalCode('const fn = (n, pow) => n ** pow; fn(2,8);') # => 256
Quickjs.evalCode('const fn = (name) => `Hi, ${name}!`; fn("Itadori");') # => "Hi, Itadori!
Quickjs.evalCode("const isOne = (n) => 1 === n; func(1);") #=> true (TrueClass)
Quickjs.evalCode("const isOne = (n) => 1 === n; func(3);") #=> false (FalseClass)

# When code returns 'object' for `typeof`, the result is converted via JSON.stringify (JS) -> JSON.parse (Ruby)
Quickjs.evalCode("[1,2,3]") #=> [1, 2, 3] (Array)
Quickjs.evalCode("({ a: '1', b: 1 })") #=> { 'a' => '1', 'b' => 1 } (Hash)

Quickjs.evalCode("null") #=> nil
Quickjs.evalCode('const obj = {}; obj.missingKey;') # => :undefined (Quickjs::Value::Undefined)
Quickjs.evalCode("Number('whatever')") #=> :NaN (Quickjs::Value::NAN)
```

## License

Every file in `ext/quickjsrb/quickjs` is licensed under [the MIT License Copyright 2017-2021 by Fabrice Bellard and Charlie Goron](/ext/quickjsrb/quickjs/LICENSE).
For otherwise, [the MIT License, Copyright 2024 by Kengo Hamasaki](/LICENSE).