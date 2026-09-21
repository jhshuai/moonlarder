# Changelog

All notable changes to this project are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project follows [Semantic Versioning](https://semver.org/), with the
usual pre-1.0 caveat that a minor bump may still include a breaking
change.

## [0.4.0]

### Added

- Property-based tests (`moonlarder_qc_test.mbt`, via
  `moonbitlang/quickcheck`) that replay randomly generated operation
  sequences and check invariants: the real LRU and LFU implementations
  agree with independent naive reference models on every hit/miss and
  on the final surviving key set, `weight()` never exceeds `capacity()`
  except by a single oversized entry, and `to_array`'s report always
  agrees with `peek`.

## [0.3.0]

### Added

- `Show`/`Debug` for `Larder`, printing a structural summary
  (`Larder(size=.., capacity=.., weight=.., policy=..)`) rather than
  dumping every entry.
- `Larder::from_array(entries, capacity~, ..., now_ms~)` — build a
  cache from an array in one call, as if `set` had been called for
  each entry in order; the usual reason is rehydrating from persisted
  state.
- `iter()`/`iter2()` — `for entry in larder { .. }` and
  `for key, value in larder { .. }` work directly, without going
  through `to_array`/`keys`/`values` first.
- A second eviction policy: `Larder::new`'s new `policy?` parameter
  accepts `Lfu` (least-frequently-used) as an alternative to the
  default `Lru`. Built the same way LRU is - reusing
  `moonbitlang/core`'s `Map` rather than a hand-rolled structure, here
  as a `Map[Int, Map[K, Unit]]` of frequency buckets implementing the
  classic O(1)-amortized LFU algorithm - and threaded through every
  operation that removes or touches an entry (`get`, `set`,
  `touch_ttl`, `remove`, `retain`, `clear`, `purge_expired`,
  `resize`). `keys()`/`values()`/`iter()`/`iter2()`/`to_array()`
  reflect plain insertion order under `Lfu`, not an eviction-meaningful
  order the way they do under `Lru`.
- `policy()` — the eviction policy a cache was created with.

## [0.2.0]

### Added

- `peek(key, now_ms~)` — read a value without affecting recency or
  hit/miss counters.
- `is_empty()`, `keys()`, `values()` — presence check and read-only
  iteration in least- to most-recently-used order.
- `to_array(now_ms~)` — a non-mutating snapshot of every non-expired
  entry.
- `retain(predicate)` — bulk conditional removal, for invalidating by
  pattern instead of key by key.
- `resize(new_capacity)` — change a cache's capacity after
  construction, evicting immediately if it shrinks below the current
  size or weight.
- `touch_ttl(key, now_ms~, ttl_ms?)` — refresh an entry's expiry in
  place (sliding expiration) without needing its value.
- Weighted-capacity mode: `Larder::new`'s new `weigher?` parameter
  turns `capacity` into a weight budget instead of a plain entry
  count, and `weight()` reports the current total. The default
  (every entry weighs 1) keeps existing behavior unchanged.
- `try_get_or_insert_with(key, now_ms~, ttl_ms?, compute)` — like
  `get_or_insert_with`, but for a loader that can fail; the error
  propagates and nothing is stored on failure.
- Benchmarks (`moon bench --target wasm-gc`) for `get`, `set`, and
  `get_or_insert_with`.

## [0.1.0]

### Added

- Initial release: `Larder[K, V]`, a bounded cache with LRU eviction
  and TTL expiry (per-entry or cache-wide default).
- `get`, `set`, `contains`, `remove`, `clear`, `purge_expired`.
- `get_or_insert_with` for memoizing a computation.
- `stats()` for hit/miss/eviction/expiration counters.
