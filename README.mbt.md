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

## API

- `Larder::new(capacity~, default_ttl_ms?)` — create a cache
- `get(key, now_ms~)` — look up a value, refreshing its recency on a hit
- `set(key, value, now_ms~, ttl_ms?)` — insert or update, evicting the
  least-recently-used entry if the cache is now over capacity
- `get_or_insert_with(key, now_ms~, ttl_ms?, compute)` — memoize
- `contains(key, now_ms~)` — check presence without affecting recency
- `remove(key)` / `clear()`
- `purge_expired(now_ms~)` — proactively sweep expired entries
- `size()` / `capacity()`
- `stats()` — hit/miss/eviction/expiration counters

See `pkg.generated.mbti` for the full signature list.

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
