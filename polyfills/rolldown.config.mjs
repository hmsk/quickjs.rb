import { defineConfig } from "rolldown";

export default [
  defineConfig({
    input: "src/intl-en.js",
    output: {
      file: "../ext/quickjsrb/vendor/polyfill-intl-en.min.js",
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
];
