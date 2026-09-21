# moonlarder

A generic in-memory cache for MoonBit with LRU eviction, TTL expiry, and a
memoizing `get_or_insert_with` helper, combined in a single bounded
structure.

## Install

```
moon add jhshuai/moonlarder
```

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

`Larder` doesn't hand-roll a linked list or a heap for either policy;
both are built on `moonbitlang/core`'s own `Map` (LRU reorders on
access the same way a real linked-list-backed LRU would; LFU keeps a
`Map[Int, Map[K, Unit]]` of frequency buckets, the same structure the
classic O(1) LFU algorithm describes, just with `Map` standing in for
the hand-rolled hash-set-plus-doubly-linked-list most implementations
use).

## API

- `Larder::new(capacity~, default_ttl_ms?, weigher?, policy?)` — create a
  cache
- `Larder::from_array(entries, capacity~, default_ttl_ms?, weigher?, policy?, now_ms~)`
  — build a cache from an array in one call, as if `set` had been called
  for each entry in order
- `get(key, now_ms~)` — look up a value, refreshing its recency on a hit
- `peek(key, now_ms~)` — read a value without affecting recency or stats
- `set(key, value, now_ms~, ttl_ms?)` — insert or update, evicting
  least-recently-used entries if the cache is now over capacity
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
random sequences each run.

## Benchmarks

```
moon bench --target wasm-gc
```

`moonlarder_bench_test.mbt` covers `get` (hit and miss), `set` at
steady state (every insert evicting one entry), and
`get_or_insert_with` on a hit, against a cache pre-warmed with 1,000
entries. `native` needs a C compiler on `PATH` the same as `moon test`
does; `wasm-gc` doesn't.

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
