# quickjs.rb

A Ruby wrapper for [QuickJS](https://bellard.org/quickjs) to run JavaScript codes via Ruby with a smaller footprint.

## Installation

```
gem install quickjs
```

```
gem 'quickjs'
```

## Features

### Evaluate JavaScript code

```rb
require 'quickjs'

Quickjs.evalCode('const fn = (n, pow) => n ** pow; fn(2,8);') # => 256
```

## License

Every file in `ext/quickjsrb/quickjs` is licensed under [the MIT License Copyright 2017-2021 by Fabrice Bellard and Charlie Goron](/ext/quickjsrb/quickjs/LICENSE). For otherwise, [the MIT License, Copyright 2024 by Kengo Hamasaki](/LICENSE).
