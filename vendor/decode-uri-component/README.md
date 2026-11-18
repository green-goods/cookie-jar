# Local decode-uri-component security remediation

This is the MIT-licensed runtime source of `decode-uri-component@0.5.1`, published by Sam Verschueren at https://github.com/SamVerschueren/decode-uri-component (tag `v0.5.1`). The upstream LICENSE and public API are retained. The package is private and is installed through the root `decode-uri-component` file override. The matching direct development dependency makes Bun install the file package on a fresh install; without it, `query-string` is left without the dependency.

GHSA-qr28-fpjm-wq7f (quadratic fallback decoding) affects every release up to 0.5.0 and is fixed in 0.5.1. The only consumer here is `query-string@7.1.3`, reached through `wagmi` and `@walletconnect/utils`. It declares `^0.2.2` and loads the package with `require()`, but 0.3.0 and later are ES modules only, so a plain registry override would hand `query-string` a module namespace instead of a function.

The one local change is the module format: `export default function` becomes a function assigned to `module.exports`, under `"use strict"`. The decoder body is byte-for-byte upstream 0.5.1. The package keeps the upstream version for provenance.

Registry audits do not scan file dependencies. `bun run test:dependency-security` therefore checks the advisory payload, upstream behaviour cases and the installed `query-string` resolution before the unchanged high/critical registry audit runs in CI. No advisory is ignored.

Remove this override and source copy once nothing in the tree depends on `decode-uri-component@^0.2`, or once a CommonJS release carries the fix.
