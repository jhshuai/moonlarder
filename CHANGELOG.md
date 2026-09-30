# Changelog

All notable changes to this project are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project follows [Semantic Versioning](https://semver.org/), with the
usual pre-1.0 caveat that a minor bump may still include a breaking
change.

## [0.15.0]

### Fixed

- `now_ms + ttl_ms` overflowing `Int64` (a TTL long enough to push the
  computed deadline past `Int64`'s max value) used to wrap around to a
  small or negative deadline, making the entry look *already expired*
  instead of long-lived - the opposite of what a very long TTL asks
  for. It now saturates to "practically never expires" instead.
- A custom `weigher` returning zero or a negative weight for some
  entry used to silently defeat `enforce_capacity`'s `current_weight >
  capacity` check (that entry contributed nothing, or shrank the
  total), letting the cache grow without bound. Every entry's weight
  is now clamped to at least 1 regardless of what `weigher` returns.

### Added

- Explicit, tested contracts for both of the above, plus a negative
  `ttl_ms`/`default_ttl_ms`: it's honored rather than rejected,
  resolving to a deadline before `now_ms` so the entry is already
  expired the moment it's looked up - the same outcome `ttl_ms=0`
  produces. Four new boundary-condition unit tests cover all three
  cases; `Larder::new`'s doc comment states them directly.

## [0.14.0]

### Added

- `cmd/main`'s `WindowTinyLfu` demo: the concrete payoff promised at
  the end of 0.13.0. Against a full, already-established cache, a
  brand-new key requested five times right after it first appears (the
  "a page that's about to go viral" pattern) is served as real cache
  hits almost immediately under `WindowTinyLfu`, since it's already
  sitting in the window - a plain `admission_filter` cache, which can
  only judge a key at `set()` time with no separate "provisionally
  cached" state, forces every one of those early requests to miss
  until the candidate accumulates enough sketch weight from its own
  miss traffic to win outright admission. Measured on one run: 4
  hits/1 miss under `WindowTinyLfu` versus 3 hits/2 misses under
  `admission_filter`, over the same 5 requests.

### Changed

- README's opening line and `cmd/main` tour description now mention
  `WindowTinyLfu` and `admission_filter` - previously one release
  behind.

## [0.13.0]

### Added

- A fourth eviction policy: `policy=WindowTinyLfu`, the windowed
  TinyLFU architecture (Einziger, Friedman, and Manes, ACM TOS 2017, as
  structured in Caffeine's implementation) - fixing `admission_filter`'s
  one real weakness, that it tests a brand-new key against the
  eviction victim on the newcomer's very first appearance, before it's
  had any chance to build up request history. Capacity splits into a
  small `Lru` window (10%, minimum 1) every new key enters first, and
  a larger main space (a segmented `Lru`: probationary + protected,
  80% of main) a window-evicted candidate only enters by winning the
  same admission contest `admission_filter` runs, just run later -
  after the window has given it a chance to prove itself with real
  hits. A probation hit promotes to protected; a protected overflow
  demotes back to probation (a pure move, never an eviction). Fixed
  fractions rather than Caffeine's adaptive, hill-climbing-tuned window
  size - a disclosed simplification. Not compatible with a custom
  `weigher`, and redundant with (so `new` aborts if combined with)
  `admission_filter`.
- Three new quickcheck properties (capacity never exceeded,
  `to_array`/`peek` agreement, `on_remove` counts matching `stats()`)
  and hand-picked unit tests walking through every mechanism -
  including a candidate that built up real frequency while sitting in
  the window beating an untouched incumbent it would have lost to
  immediately under a plain `admission_filter`.
- Fixed a real bug caught during this work before it shipped:
  `admission_filter`'s own admission check (`rejects_admission`) was
  gated only on `self.sketch` being present, which `WindowTinyLfu` also
  populates for its own unrelated purposes - so without an explicit
  policy check, `WindowTinyLfu` would have had the `Lru`-shaped
  admission_filter check silently running on top of its own window
  logic on every insert. Caught by re-reading the interaction between
  the two features before writing tests, not by a failing test.

README explains the mechanism, but `cmd/main` doesn't have a
`WindowTinyLfu` demo yet - a concrete, running side-by-side proof
against a plain `admission_filter` cache, the same way `Arc`'s demo
proves its own value against plain `Lru`; that's next.

## [0.12.0]

### Added

- `Larder::new`'s `admission_filter?` parameter: a TinyLFU-style
  admission check (Einziger, Friedman, and Manes, ACM TOS 2017) that
  puts the new `FrequencySketch` to work in front of `Lru` eviction.
  Every `get()` records the key it looked up (hit or miss); when a
  brand-new key would need to evict an existing entry to fit, the
  eviction only happens if the newcomer is estimated at least as
  popular as the entry it would displace, otherwise the newcomer is
  turned away and the cache is left exactly as it was. A second,
  differently-mechanised defense against the same one-time-scan
  problem `policy=Arc` solves - a scan's keys have no request history,
  so they lose the comparison against anything genuinely
  frequently-requested. Only supported together with `policy=Lru` and
  without a custom `weigher` - `new` aborts if combined with
  `Lfu`/`Arc` or a `weigher`.
- `admission_rejections()` - how many newcomers the filter has turned
  away; always `0` when it isn't enabled.
- `cmd/main` runs the same hot-set-plus-scan workload as the `Arc` demo
  through a plain `Lru` cache and an admission-filtered one side by
  side.
- A new quickcheck property (capacity never exceeded by a rejected
  insert) and hand-picked unit tests for the admission decision itself,
  including the "a tie favors the newcomer" rule that keeps a cold
  sketch from rejecting every insert.

## [0.11.0]

### Added

- `FrequencySketch[K]` - a Count-Min Sketch (Cormode and Muthukrishnan,
  "An Improved Data Stream Summary: The Count-Min Sketch and its
  Applications", 2005): a fixed-space, approximate "how many times
  have I seen this key?" counter, sized and aged (capped counters,
  periodic halving) the way Einziger, Friedman, and Manes' TinyLFU uses
  one for cache admission decisions. Public and useful independent of
  `Larder` - `K` only needs `Hash`, not `Eq`, since a sketch never
  stores or compares keys, only the positions their hashes land on.
  Covered by hand-picked unit tests (saturation, aging, independence
  between unrelated keys) and a new quickcheck property differentially
  testing `estimate` against a naive exact `Map[K, Int]` of true
  counts - the defining Count-Min Sketch guarantee (`estimate` never
  underestimates, up to its own cap). Not yet wired into `Larder`
  itself; see the next release for that.

## [0.10.0]

### Added

- `get_many(keys, now_ms~)` / `set_many(entries, now_ms~, ttl_ms?)` -
  batch lookups and inserts, exactly equivalent to calling `get`/`set`
  on each key or entry in turn (same recency updates, same `stats()`
  counting, capacity enforced entry-by-entry for `set_many` so an
  earlier entry in the array can be evicted to make room for a later
  one in the same call). Covers the common "look up a page of IDs" or
  "warm the cache from rows just read from a database" case without
  every call site writing its own loop.

## [0.9.0]

### Added

- A third eviction policy: `Larder::new`'s `policy?` parameter now also
  accepts `Arc` - Adaptive Replacement Cache (Megiddo and Modha, "ARC:
  A Self-Tuning, Low Overhead Replacement Cache", FAST 2003), the
  algorithm behind ZFS's and PostgreSQL's buffer caches. Unlike `Lru`
  (recency only) or `Lfu` (frequency only), `Arc` adapts between the
  two based on the cache's own observed hit pattern, without any
  parameter to tune - implemented, like `Lru`/`Lfu`, on top of
  `moonbitlang/core`'s `Map` rather than a hand-rolled structure
  (`arc_t1`/`arc_t2` for real entries, `arc_b1`/`arc_b2` ghost lists of
  recently evicted keys, and an adaptive target size `arc_p`). Not
  compatible with a custom `weigher` - `new` aborts if both are given -
  and its ghost-list bookkeeping is driven by `set()`, since this
  library's `get`/`set` split doesn't give a single "request" event the
  way the original algorithm assumes.
- `cmd/main`'s tour now includes a side-by-side `Arc` vs. `Lru` demo: a
  small hot working set followed by a one-time sequential scan, the
  textbook case where plain LRU evicts the entire working set and ARC
  doesn't.
- Three new quickcheck properties (`Arc` never exceeds capacity, its
  `to_array` always agrees with `peek`, its `on_remove` firing counts
  match `stats()`) alongside hand-picked unit tests covering T1-to-T2
  promotion, both ghost-list hit cases, and cleanup on `remove`/`resize`.

## [0.8.0]

### Added

- Removal listeners: `Larder::new`'s new `on_remove?` parameter is
  called synchronously whenever an entry leaves the cache, with a
  `RemovalCause` (`Explicit`, `Replaced`, `Expired`, or `Evicted`).
  Fired after the cache's own state already reflects the removal, so a
  listener can safely call back into the same cache. `from_array`
  gained the same `on_remove?` parameter; `from_json` always uses the
  default no-op listener, for the same reason it can't deserialize a
  custom `weigher` (both are functions).
- A new quickcheck property (`on_remove firing counts match stats()
  exactly`) cross-checks the listener against the existing, separately
  maintained hit/miss/eviction/expiration counters over random
  operation sequences.

## [0.7.0]

### Added

- `moonlarder_scaling_bench_test.mbt`: benchmarks `get`/`set` against a
  deliberately naive O(capacity) reference LRU cache at capacities
  100/1,000/10,000, to make the payoff of the `Map`-backed O(1) design
  measurable rather than asserted. See the README's "Does the
  `Map`-based design actually pay for itself?" section for results.

## [0.6.0]

### Added

- `cmd/main`, a runnable tour (`moon run cmd/main --target wasm-gc`) of
  LRU eviction, TTL expiry, memoization, weighted capacity, the LFU
  policy, and JSON snapshotting. Uses an explicit `now_ms` throughout,
  so its output is identical on every target. Now part of CI.

## [0.5.0]

### Added

- `ToJson`/`FromJson` for `Larder[K, V]` (when `K`/`V` implement them):
  `{"capacity": .., "policy": "lru"|"lfu", "entries": [{"key": ..,
  "value": ..}, ..]}`. A snapshot of contents, not a byte-for-byte save
  state - LRU recency, LFU frequencies, and TTLs don't round-trip, and
  `FromJson` always reconstructs with the default (count-based)
  weigher, since a weigher is a function with nothing in JSON to
  deserialize it from. Covered by a new property test asserting a JSON
  round trip preserves every live entry, on top of the hand-picked
  cases in `moonlarder_test.mbt`.

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
