import { readFileSync } from "fs";

const lock = JSON.parse(readFileSync(new URL("./package-lock.json", import.meta.url)));

const ROOT_PACKAGES = [
  "@formatjs/intl-getcanonicallocales",
  "@formatjs/intl-locale",
  "@formatjs/intl-pluralrules",
  "@formatjs/intl-numberformat",
  "@formatjs/intl-datetimeformat",
];

const BUILD_ONLY = new Set([
  "rolldown", "@rolldown/pluginutils", "@oxc-project/types",
  "@emnapi/core", "@emnapi/runtime", "@emnapi/wasi-threads",
  "@napi-rs/wasm-runtime", "@tybys/wasm-util",
]);

function collectDeps(pkgName, visited = new Set()) {
  if (visited.has(pkgName) || BUILD_ONLY.has(pkgName)) return visited;
  visited.add(pkgName);
  const info = lock.packages[`node_modules/${pkgName}`];
  if (!info) return visited;
  for (const dep of Object.keys({ ...info.dependencies, ...info.peerDependencies ?? {} })) {
    collectDeps(dep, visited);
  }
  return visited;
}

const allDeps = new Set();
for (const root of ROOT_PACKAGES) collectDeps(root, allDeps);

let hasError = false;
const byYear = {};

for (const pkg of [...allDeps].sort()) {
  let licenseText;
  try {
    licenseText = readFileSync(`node_modules/${pkg}/LICENSE.md`, "utf8");
  } catch {
    try {
      licenseText = readFileSync(`node_modules/${pkg}/LICENSE`, "utf8");
    } catch {
      console.error(`ERROR: No license file found for ${pkg}`);
      hasError = true;
      continue;
    }
  }

  const isMIT = licenseText.includes("MIT License");
  const yearMatch = licenseText.match(/Copyright\s+\(c\)\s+(\d{4})/i);
  const authorMatch = licenseText.match(/Copyright\s+\(c\)\s+\d{4}\s+(.+)/i);

  if (!isMIT) {
    console.error(`ERROR: ${pkg} is NOT MIT licensed`);
    hasError = true;
  }

  const year = yearMatch?.[1] ?? "unknown";
  const author = authorMatch?.[1]?.trim() ?? "unknown";
  byYear[year] ??= { author, packages: [] };
  byYear[year].packages.push(pkg);
}

console.log("Bundled dependencies by copyright year:\n");
for (const year of Object.keys(byYear).sort()) {
  const { author, packages } = byYear[year];
  console.log(`  MIT License Copyright (c) ${year} ${author}`);
  for (const pkg of packages) console.log(`    - ${pkg}`);
}

if (hasError) process.exit(1);
