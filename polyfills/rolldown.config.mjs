import { defineConfig } from "rolldown";

export default [
  defineConfig({
    input: "src/intl-en.js",
    output: {
      // Loaded at runtime by lib/quickjs/polyfills/intl.rb via
      // Quickjs.register_polyfill; other entries are still embedded as
      // pre-compiled bytecode in the .so until they go the same way.
      file: "../lib/quickjs/polyfills/intl-en.min.js",
      format: "iife",
      minify: true,
    },
  }),
  defineConfig({
    input: "src/file.js",
    output: {
      file: "../ext/quickjsrb/vendor/polyfill-file.min.js",
      format: "iife",
      minify: true,
    },
  }),
  defineConfig({
    input: "src/encoding.js",
    output: {
      file: "../ext/quickjsrb/vendor/polyfill-encoding.min.js",
      format: "iife",
      minify: true,
    },
  }),
  defineConfig({
    input: "src/url.js",
    output: {
      file: "../ext/quickjsrb/vendor/polyfill-url.min.js",
      format: "iife",
      minify: true,
    },
  }),
];
