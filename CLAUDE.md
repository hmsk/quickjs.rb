# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

quickjs.rb is a Ruby gem wrapping QuickJS (a lightweight JavaScript interpreter) via a C extension. It lets Ruby programs evaluate JavaScript code without a full Node.js runtime.

## Build & Test Commands

```bash
bundle exec rake              # Full cycle: clobber → compile → test
bundle exec rake compile      # Compile C extension only
bundle exec rake test         # Run all tests
bundle exec ruby -Itest:lib test/quickjs_test.rb              # Run single test file
bundle exec ruby -Itest:lib test/quickjs_test.rb -n test_name # Run single test
rake polyfills:build          # Rebuild Intl polyfill bundle (requires npm)
```

QuickJS source lives as a git submodule under `ext/quickjsrb/quickjs/` — clone with `--recurse-submodules`.

## Design Principles

- **Never modify QuickJS core** — the engine is a git submodule; all customization is implemented externally in our C extension or Ruby layer
- **Prefer Ruby over C** — don't rush to write C code; use Ruby where it provides better extendability and maintainability
- **Security-conscious C layer** — avoid adding flexible C-level features that introduce security risks; expose QuickJS's own options as-is rather than inventing new attack surface
- **Keep the default footprint small** — don't increase bundle size or add JavaScript overhead (e.g. polyfills) by default; additional capabilities should be opt-in via feature flags

## Architecture

**C Extension** (`ext/quickjsrb/`):
- `quickjsrb.c` / `quickjsrb.h` — Core extension: creates QuickJS runtime/context, handles Ruby↔JS value conversion, timeout interrupts, and Ruby function bridging into JS
- Value conversion uses JSON serialization for complex types (objects/arrays); direct conversion for primitives
- `VMData` struct holds the JS context, defined Ruby functions, timeout state, console logs, and error references
- Ruby GC integration via `vm_mark`, `vm_free`, `vm_compact` callbacks

**Ruby layer** (`lib/quickjs/`):
- `Quickjs::VM` — Persistent JS runtime with `eval_code`, `import`, `define_function`
- `Quickjs.eval_code` — Convenience method for one-shot evaluation
- Exception hierarchy maps JS error types (SyntaxError, TypeError, etc.) to Ruby classes under `Quickjs::`
- Special values: `Quickjs::Value::UNDEFINED` and `Quickjs::Value::NAN` represent JS undefined/NaN

**Feature flags** (passed to `VM.new` via `features:` array):
- `:feature_std`, `:feature_os` — QuickJS std/os modules
- `:feature_timeout` — setTimeout/setInterval via CRuby threads
- `:feature_polyfill_intl` — Intl API polyfill (DateTimeFormat, NumberFormat, PluralRules, Locale)

**Polyfills** (`polyfills/`):
- Built from FormatJS packages via rolldown, output minified JS embedded as C source
- Polyfill version must match gem version (enforced during `rake release`)

## Testing

Tests use minitest with `describe`/`it` blocks. Key test files:
- `test/quickjs_test.rb` — Main test suite (value conversion, errors, VM features, ESM imports, function definitions)
- `test/quickjs_polyfill_test.rb` — Intl polyfill tests

## Build Notes

- `extconf.rb` compiles with `-DNDEBUG` to avoid conflicts with Ruby 4.0 GC assertions
- Symbol visibility is hidden by default (`-fvisibility=hidden`)
- CI matrix: Ruby 3.2/3.3/3.4/4.0 × Ubuntu/macOS
