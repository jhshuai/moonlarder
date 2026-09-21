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

## API

- `Larder::new(capacity~, default_ttl_ms?, weigher?)` — create a cache
- `Larder::from_array(entries, capacity~, default_ttl_ms?, weigher?, now_ms~)`
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
- `is_empty()` / `size()` / `capacity()` / `weight()` / `resize(capacity)`
- `stats()` — hit/miss/eviction/expiration counters

See `pkg.generated.mbti` for the full signature list.

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
