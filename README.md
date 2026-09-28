# moonlarder

A generic in-memory cache for MoonBit with a choice of LRU, LFU, or ARC
eviction, TTL expiry, and a memoizing `get_or_insert_with` helper,
combined in a single bounded structure.

## Install

```
moon add jhshuai/moonlarder
```

## Try it

```
moon run cmd/main --target wasm-gc
```

`cmd/main` is a runnable tour of LRU eviction, TTL expiry, memoization,
weighted capacity, the LFU and ARC policies, and JSON snapshotting -
each step
prints what it did and why. It uses an explicit `now_ms` throughout
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

`Larder[K, V]` implements `ToJson`/`FromJson` when `K`/`V` do, for
persisting and rehydrating a cache across a restart:

```moonbit nocheck
let snapshot : Json = ToJson::to_json(cache)
let restored : Larder[String, Int] = @json.from_json(snapshot)
```

The snapshot is `{"capacity": .., "policy": "lru"|"lfu"|"arc", "entries":
[{"key": .., "value": ..}, ..]}`. It's a snapshot of *contents*, not a
byte-for-byte save state: LRU recency order, LFU frequencies, ARC's
T1/T2/ghost-list state, and TTLs don't survive the round trip (a
reloaded entry never expires on its
own, and `FromJson` always uses the default count-based weigher, since
a weigher is a function and there's nothing in JSON to deserialize it
from). Use `to_array`/`from_array` directly, supplying your own
`weigher`/`default_ttl_ms`, if you need either preserved.

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

- `Larder::new(capacity~, default_ttl_ms?, weigher?, policy?, on_remove?)`
  — create a cache
- `Larder::from_array(entries, capacity~, default_ttl_ms?, weigher?, policy?, on_remove?, now_ms~)`
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
- `stats()` — hit/miss/eviction/expiration counters
- `on_remove` — notified synchronously whenever an entry leaves, with
  why (`Explicit`, `Replaced`, `Expired`, or `Evicted`); see below
- `ToJson`/`FromJson` — snapshot to and rehydrate from JSON (see above)

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

## Notes

- Not thread-safe; use one `Larder` per thread or add your own
  synchronization if you need to share one.
- Keys must implement `Hash + Eq`.
- Expiry is lazy: an expired entry is only removed when it's looked up
  (`get`/`contains`) or via an explicit `purge_expired`, so a
  write-heavy, rarely-read workload can hold expired entries until one
  of those runs.

## License

Apache-2.0, see `LICENSE`.
