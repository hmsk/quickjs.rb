# frozen_string_literal: true

# FormatJS Intl polyfill (`en` locale only — getCanonicalLocales, Locale,
# PluralRules, NumberFormat, DateTimeFormat). Compiled and cached on first
# VM that enables the feature; the file is not read until then.

Quickjs.register_polyfill(
  Quickjs::POLYFILL_INTL,
  source: -> { File.read(File.expand_path('intl-en.min.js', __dir__)) },
  init: "Object.defineProperty(globalThis, 'Intl', { value:{} });"
)
