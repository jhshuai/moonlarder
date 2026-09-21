// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "jhshuai/moonlarder"

version = "0.5.0"

readme = "README.md"

repository = "https://github.com/jhshuai/moonlarder"

license = "Apache-2.0"

keywords = [ "cache", "lru", "ttl", "memoize", "data-structures" ]

preferred_target = "wasm"

description = "A generic in-memory cache with LRU eviction, TTL expiry, and a memoizing get-or-insert helper"

import {
  "moonbitlang/quickcheck@0.14.0",
}
