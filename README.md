# moonlarder

[![CI](https://github.com/jhshuai/moonlarder/actions/workflows/ci.yml/badge.svg)](https://github.com/jhshuai/moonlarder/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/github/license/jhshuai/moonlarder)](LICENSE)

A generic in-memory cache for MoonBit with a choice of LRU, LFU, ARC,
or windowed TinyLFU eviction (plus a standalone TinyLFU-style
admission filter for LRU), TTL expiry, and a memoizing
`get_or_insert_with` helper, combined in a single bounded structure.

## Install

```
moon add jhshuai/moonlarder
```

## Try it

```
moon run cmd/main --target wasm-gc
```

`cmd/main` is a runnable tour of LRU eviction, TTL expiry, memoization,
weighted capacity, the LFU, ARC, and WindowTinyLfu policies, the
admission filter, and JSON snapshotting - each step prints what it did
and why. It uses an explicit `now_ms` throughout
rather than a real clock (the same as everything else in this
library), so its output is identical on every target: swap `wasm-gc`
for `wasm`, `js`, or `native` (the last needs a C compiler on `PATH`,
same as `moon test` does) and nothing about the demo itself changes.

## Why

A cache that only evicts by size (plain LRU) can't drop stale entries on
its own, and a cache that only expires by time (plain TTL) can grow
without bound. `Larder` does both at once: it holds at most `capacity`
entries, evicting the least-recently-used one to make room, and it treats
any entry past its time-to-live as absent the next time it's looked up.

The clock is never read internally. Every call that needs one takes a
`now_ms : Int64` argument instead, so a cache's behavior is deterministic
and testable without depending on a wall clock or a particular target's
time source.

## Usage

```moonbit nocheck
let cache : Larder[String, Int] = Larder::new(capacity=100, default_ttl_ms=60_000L)

cache.set("answer", 42, now_ms=0L)
cache.get("answer", now_ms=1_000L) // Some(42)

// Memoize an expensive computation: recomputed only on a miss or expiry.
let value = cache.get_or_insert_with("expensive", now_ms=0L, fn() {
  compute_expensive_thing()
})
```

Per-entry TTL overrides the cache-wide default:

```moonbit nocheck
cache.set("short-lived", "value", now_ms=0L, ttl_ms=5_000L)
```

`get_many`/`set_many` cover the batch case - looking up a page of IDs,
or warming the cache from rows just read from a database - without
writing the loop yourself at every call site:

```moonbit nocheck
cache.set_many([("a", 1), ("b", 2), ("c", 3)], now_ms=0L)
let found = cache.get_many(["a", "missing", "c"], now_ms=0L)
// found == [("a", 1), ("c", 3)] - only the hits, in the order asked
```

Each is exactly equivalent to calling `get`/`set` on every key or entry
in turn - same recency updates, same `stats()` counting, and (for
`set_many`) capacity is enforced as each entry goes in, so an entry
earlier in the array can be evicted to make room for one later in the
same call.

By default, `capacity` counts entries. Pass `weigher` to weigh entries by
something else instead - total byte size, say, so a handful of large
values can't crowd out many small ones the way plain entry-counting
would let them:

```moonbit nocheck
let by_size : Larder[String, Bytes] = Larder::new(
  capacity=10 * 1024 * 1024, // 10 MiB total, not 10 MiB per entry
  weigher=fn(_key, value) { value.length() },
)
```

An entry whose own weight exceeds `capacity` is still admitted alone
(evicting everything else) rather than rejected, since `set` never fails.

By default a full cache evicts by least-recently-used (LRU). Pass
`policy=Lfu` for least-frequently-used eviction instead - keeping
entries that get reused often even if they haven't been touched
*recently*, at the cost of a brand-new entry being evictable almost
immediately if the cache is already full of entries used more than
once (that's LFU's own definition at work, not a bug):

```moonbit nocheck
let cache : Larder[String, Int] = Larder::new(capacity=100, policy=Lfu)
```

For workloads with both a hot, frequently-reused set of keys and
occasional one-time bulk scans that shouldn't be allowed to evict it,
`policy=Arc` runs Adaptive Replacement Cache (Megiddo and Modha, FAST
2003 - the algorithm ZFS's and PostgreSQL's buffer caches are built
on), which adapts between recency and frequency on its own rather than
committing to one the way `Lru`/`Lfu` do, with no parameter to tune:

```moonbit nocheck
let cache : Larder[String, Int] = Larder::new(capacity=100, policy=Arc)
```

`Arc` isn't compatible with a custom `weigher` - `new` aborts if both
are given - and its ghost-list bookkeeping (which real entry was
recently evicted, and from where) is driven by `set()`, since this
library's separate `get`/`set` calls don't give it the single "cache
request" event the original algorithm is built around; see
`EvictionPolicy::Arc`'s doc comment for the exact adaptation. `cmd/main`
includes a side-by-side demo against plain LRU under a hot-set-plus-scan
workload - the textbook case ARC exists for.

`Larder` doesn't hand-roll a linked list or a heap for any of the three
policies; all are built on `moonbitlang/core`'s own `Map` (LRU reorders
on access the same way a real linked-list-backed LRU would; LFU keeps a
`Map[Int, Map[K, Unit]]` of frequency buckets, the same structure the
classic O(1) LFU algorithm describes; ARC keeps four such `Map`s - two
for real entries, two ghost lists of evicted keys - standing in for the
paper's own linked lists, just with `Map` for the hand-rolled
hash-set-plus-doubly-linked-list most implementations use).

### Frequency estimation

`FrequencySketch[K]` is a Count-Min Sketch (Cormode and Muthukrishnan,
2005) - a fixed-space, approximate "how many times have I seen this
key?" counter, the building block TinyLFU-style cache admission
policies use to judge whether a newcomer is popular enough to deserve
displacing an existing entry. It's public and useful on its own,
independent of `Larder`:

```moonbit nocheck
let sketch : FrequencySketch[String] = FrequencySketch::new(capacity=10_000)
sketch.increment("popular-key")
sketch.increment("popular-key")
sketch.estimate("popular-key") // 2 - never lower than the true count,
                                // possibly higher from hash collisions
```

Space stays fixed no matter how many distinct keys are ever seen -
the trade against an exact `Map[K, Int]` - and counts are capped and
periodically halved so `estimate` tracks *recent* popularity rather
than accumulating forever.

`Larder::new`'s `admission_filter=true` puts a `FrequencySketch` to
work as a TinyLFU-style admission check (Einziger, Friedman, and
Manes, ACM TOS 2017) in front of `Lru` eviction - a second, different
defense against the same one-time-scan problem `policy=Arc` solves:

```moonbit nocheck
let cache : Larder[String, Int] = Larder::new(capacity=100, admission_filter=true)
```

Every `get()` (hit or miss) records the key it looked up in the
filter's sketch. When a brand-new key would need to evict an existing
entry to fit, that eviction happens only if the newcomer is estimated
*at least as* popular as the entry it would displace - otherwise the
newcomer is turned away outright and the cache is left exactly as it
was (`admission_rejections()` counts how often this fires). This is
what keeps a one-time bulk scan from wiping out a genuinely
frequently-requested working set: the scan's keys have no request
history, so they lose the comparison against anything that's actually
been asked for more than once.

`admission_filter` is only supported together with `policy=Lru` (the
default) and without a custom `weigher` - `new` aborts if combined
with `Lfu`/`Arc` or a `weigher`. `cmd/main` runs the same
hot-set-plus-scan workload as the `Arc` demo through both a plain
`Lru` cache and an admission-filtered one, side by side.

`admission_filter` has one real weakness: it tests a brand-new key
against the eviction victim on the newcomer's very first appearance,
before it's had any chance to build up request history of its own - so
a key that's genuinely about to become popular can still lose that
first comparison and never get a second chance. `policy=WindowTinyLfu`
fixes exactly that, with a different architecture rather than a tunable
knob:

```moonbit nocheck
let cache : Larder[String, Int] = Larder::new(capacity=100, policy=WindowTinyLfu)
```

Instead of gating every insert directly, capacity is split into a
small `Lru` **window** (10%, minimum 1 entry) and a larger **main**
space every new key must earn its way into. Every new key lands in the
window first; only once the window itself overflows does the evicted
candidate contest admission into main - by which point it's had a
chance to accumulate real hits (each promoting it within the window,
buying more time) if it's actually being requested repeatedly. Main
itself is a segmented `Lru` (SLRU): a probationary segment newly
admitted keys enter, and a protected segment (80% of main) a
probationary entry is promoted into on its first hit there, demoting
protected's own least-recently-used entry back to probation if that
promotion overflows it - a pure move between the two segments, never
an eviction. The admission contest itself is the same frequency
comparison `admission_filter` runs, just applied later, after the
window has given the candidate a chance to prove itself.

These are fixed fractions (Caffeine's own defaults), not the adaptive,
hill-climbing-tuned window size the production system uses - a
disclosed simplification, not an attempt at byte-for-byte parity.
`WindowTinyLfu` isn't compatible with a custom `weigher`, and is
redundant with (so `new` aborts if combined with) `admission_filter`,
since this policy already runs its own version of the same idea.

`cmd/main` demonstrates the concrete payoff against a full,
already-established cache: a brand-new key requested five times right
after it first appears (the "a page that's about to go viral" pattern)
gets served as real cache hits almost immediately under
`WindowTinyLfu`, because it's already sitting in the window, while a
plain `admission_filter` cache - which can only judge it at `set()`
time, with no separate "already provisionally cached" state - forces
every one of those early requests to miss until the candidate finally
accumulates enough sketch weight from its own miss traffic to win
outright admission.

`Larder[K, V]` implements `ToJson`/`FromJson` when `K`/`V` do, for
persisting and rehydrating a cache across a restart:

```moonbit nocheck
let snapshot : Json = ToJson::to_json(cache)
let restored : Larder[String, Int] = @json.from_json(snapshot)
```

The snapshot is `{"capacity": .., "policy": "lru"|"lfu"|"arc"|"wtinylfu",
"entries": [{"key": .., "value": ..}, ..]}`. It's a snapshot of
*contents*, not a byte-for-byte save state: LRU recency order, LFU
frequencies, ARC's T1/T2/ghost-list state, WindowTinyLfu's window/main
membership, and TTLs don't survive the round trip (a reloaded entry
never expires on its
own, and `FromJson` always uses the default count-based weigher and
leaves the admission filter off, since a weigher is a function and
there's nothing in JSON to deserialize a filter's sketch state from
either). Use `to_array`/`from_array` directly, supplying your own
`weigher`/`default_ttl_ms`/`admission_filter`, if you need any of them
preserved.

Pass `on_remove` to be notified whenever an entry leaves the cache, and
why - useful for cascading invalidation, releasing a resource tied to
the value (closing a file handle, say), or metrics:

```moonbit nocheck
let cache : Larder[String, Handle] = Larder::new(
  capacity=1000,
  on_remove=fn(_key, handle, _cause) { handle.close() },
)
```

`_cause` is `Explicit` (`remove`/`retain`/`clear`), `Replaced`
(overwritten by `set` on a key already present - the *old* value is
what's being discarded, not the new one), `Expired`, or `Evicted`.
The listener runs synchronously, after the cache's own state already
reflects the removal - so it's safe for a listener to call back into
the same cache (check `size()`, even insert a replacement) without
seeing a half-finished removal.

## API

- `Larder::new(capacity~, default_ttl_ms?, weigher?, policy?, admission_filter?, on_remove?)`
  — create a cache
- `Larder::from_array(entries, capacity~, default_ttl_ms?, weigher?, policy?, admission_filter?, on_remove?, now_ms~)`
  — build a cache from an array in one call, as if `set` had been called
  for each entry in order
- `get(key, now_ms~)` — look up a value, refreshing its recency on a hit
- `get_many(keys, now_ms~)` — look up several keys in one call,
  returning only the hits, in order
- `peek(key, now_ms~)` — read a value without affecting recency or stats
- `set(key, value, now_ms~, ttl_ms?)` — insert or update, evicting
  least-recently-used entries if the cache is now over capacity
- `set_many(entries, now_ms~, ttl_ms?)` — insert or update several
  entries under one ttl in one call
- `get_or_insert_with(key, now_ms~, ttl_ms?, compute)` — memoize
- `try_get_or_insert_with(key, now_ms~, ttl_ms?, compute)` — memoize a
  loader that can fail; the error propagates and nothing is stored
- `touch_ttl(key, now_ms~, ttl_ms?)` — refresh an entry's expiry in place
  (sliding expiration) without needing its value
- `contains(key, now_ms~)` — check presence without affecting recency
- `remove(key)` / `clear()` / `retain(predicate)`
- `purge_expired(now_ms~)` — proactively sweep expired entries
- `keys()` / `values()` / `to_array(now_ms~)` — inspect current contents
- `iter()` / `iter2()` — support `for entry in larder { .. }` and
  `for key, value in larder { .. }` directly
- `is_empty()` / `size()` / `capacity()` / `weight()` / `resize(capacity)`
- `policy()` — the eviction policy this cache was created with
- `admission_rejections()` — how many newcomers `admission_filter` has
  turned away; always `0` when it isn't enabled
- `stats()` — hit/miss/eviction/expiration counters
- `on_remove` — notified synchronously whenever an entry leaves, with
  why (`Explicit`, `Replaced`, `Expired`, or `Evicted`); see below
- `ToJson`/`FromJson` — snapshot to and rehydrate from JSON (see above)

`FrequencySketch[K]`, independent of `Larder`:

- `FrequencySketch::new(capacity~)` — create an empty sketch
- `increment(key)` — record one occurrence of `key`
- `estimate(key)` — an approximate count, never below the true count
  while under the per-counter cap (15)
- `clear()` — reset every counter to zero

See `pkg.generated.mbti` for the full signature list.

## Testing

Beyond the hand-picked unit tests in `moonlarder_test.mbt`,
`moonlarder_qc_test.mbt` uses [`moonbitlang/quickcheck`](https://mooncakes.io/docs/moonbitlang/quickcheck)
to replay randomly generated sequences of operations and check
invariants that must hold no matter what produced the current state -
most notably, that the real `Map`-based LRU and LFU implementations
agree with independent, deliberately naive reference models (plain
arrays and linear scans, no shared code with the real implementation)
on every hit/miss and on the final set of surviving keys, across 100
random sequences each run. `Arc` gets its own properties in the same
file (capacity never exceeded, `to_array`/`peek` agreement, `on_remove`
counts matching `stats()`) rather than a naive reference model, since a
trustworthy independent model of an adaptive algorithm is itself
nontrivial to write; hand-picked unit tests in `moonlarder_test.mbt`
cover the specific cases (T1-to-T2 promotion, both ghost-list hits) a
random sequence might take a while to stumble onto reliably.

`frequency_sketch_qc_test.mbt` does the same differential comparison
for `FrequencySketch`, against a naive exact `Map[K, Int]` of true
counts: `estimate(key)` must never fall below `key`'s true count (up
to the sketch's own cap), the defining Count-Min Sketch guarantee.
`admission_filter` gets its own capacity-invariant property (a
rejected insert must leave the cache exactly as it was) plus
hand-picked unit tests for the admission decision itself - both the
rejection case and the "a tie favors the newcomer" rule that keeps a
cold sketch from degenerating into rejecting every insert.
`WindowTinyLfu` gets the same three properties (capacity,
`to_array`/`peek` agreement, `on_remove` counts) `Arc` does, plus
hand-picked unit tests walking through each mechanism by hand: window
overflow admitting into probation, a probation hit promoting to
protected, a protected overflow demoting back to probation without
evicting anything, the admission contest itself picking a winner, and
- the whole point of the window - a candidate that built up real
frequency while still sitting there beating an untouched incumbent it
would have lost to immediately under a plain `admission_filter`.

## Benchmarks

```
moon bench --target wasm-gc
```

`moonlarder_bench_test.mbt` covers `get` (hit and miss), `set` at
steady state (every insert evicting one entry), and
`get_or_insert_with` on a hit, against a cache pre-warmed with 1,000
entries. `native` needs a C compiler on `PATH` the same as `moon test`
does; `wasm-gc` doesn't.

### Does the `Map`-based design actually pay for itself?

`moonlarder_scaling_bench_test.mbt` answers that directly: it
benchmarks `get`/`set` against a deliberately naive LRU cache - a
plain array, linearly scanned and rebuilt on every operation, the way
a cache gets written before reaching for a `Map` - at capacities 100,
1,000, and 10,000. Measured on one run of this repository's CI-shaped
environment (absolute numbers will vary by machine; the *trend* is
the point):

| capacity | `get`, real | `get`, naive | ratio | `set`, real | `set`, naive | ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 100 | 86 ns | 849 ns | ~10x | 141 ns | 827 ns | ~5.9x |
| 1,000 | 28.6 ns | 4.09 µs | ~143x | 72.3 ns | 6.92 µs | ~96x |
| 10,000 | 26.1 ns | 87.7 µs | ~3,360x | 211 ns | 169.3 µs | ~800x |

The real implementation stays roughly flat (even improving slightly,
likely from cache-friendlier access patterns at this scale) as
capacity grows 100x, exactly as expected for O(1)-amortized
operations; the naive one degrades close to linearly, since every one
of its operations costs O(capacity). The gap is already an order of
magnitude at capacity 100 and three orders of magnitude by 10,000 -
the frequency-bucket/`Map`-reinsertion design isn't just asymptotically
nicer on paper, it's the difference between a cache that's free to use
liberally and one that becomes the bottleneck as it grows.

## Real-world usage

Benchmarks prove the design is fast in isolation; they don't prove the
API actually holds up as a dependency in someone else's code. So
[`jhshuai/moonlarder-shortlink`](https://github.com/jhshuai/moonlarder-shortlink)
exists to answer that directly: a small URL-shortener core built
*against* `moonlarder` as a real, separately-versioned import (resolved
via `moon.work` in development, the same way a monorepo or a
pre-publish integration check would), not copy-pasted code sharing
this repository's build.

It's a genuine two-cache-shapes-in-one-system example - `get_or_insert_with`
for memoizing code generation, and a capacity-and-TTL-bounded `Larder`
for the reverse lookup a resolver can't hold forever - and it ships its
own honest benchmark of when memoization actually pays off (spoiler:
not always; see its README for the measured case where it doesn't).

## Notes

- Not thread-safe; use one `Larder` per thread or add your own
  synchronization if you need to share one.
- Keys must implement `Hash + Eq`.
- Expiry is lazy: an expired entry is only removed when it's looked up
  (`get`/`contains`) or via an explicit `purge_expired`, so a
  write-heavy, rarely-read workload can hold expired entries until one
  of those runs.
- A negative `ttl_ms`/`default_ttl_ms` is honored, not rejected: the
  entry is already expired the moment it's looked up. A `ttl_ms` large
  enough to overflow `Int64` saturates to "practically never expires"
  rather than wrapping around to a deadline in the past. A `weigher`
  returning zero or a negative weight is clamped to at least 1, so it
  can never silently defeat capacity enforcement.

## License

Apache-2.0, see `LICENSE`.
