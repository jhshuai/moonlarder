///|
test "get on an empty cache is a miss" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  assert_eq(c.get("a", now_ms=0L), None)
  assert_eq(c.stats(), { hits: 0, misses: 1, evictions: 0, expirations: 0, })
}

///|
test "set then get returns the value and counts a hit" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  assert_eq(c.get("a", now_ms=1L), Some(1))
  assert_eq(c.stats(), { hits: 1, misses: 0, evictions: 0, expirations: 0, })
}

///|
test "set on an existing key updates the value without growing size" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  c.set("a", 2, now_ms=0L)
  assert_eq(c.size(), 1)
  assert_eq(c.get("a", now_ms=0L), Some(2))
}

///|
test "inserting past capacity evicts the least-recently-used entry" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  c.set("b", 2, now_ms=0L)
  c.set("c", 3, now_ms=0L) // "a" was never touched again, so it goes
  assert_eq(c.get("a", now_ms=0L), None)
  assert_eq(c.get("b", now_ms=0L), Some(2))
  assert_eq(c.get("c", now_ms=0L), Some(3))
  assert_eq(c.stats().evictions, 1)
}

///|
test "get refreshes recency so the touched entry survives eviction" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  c.set("b", 2, now_ms=0L)
  ignore(c.get("a", now_ms=0L)) // "a" is now more recent than "b"
  c.set("c", 3, now_ms=0L) // "b" should be evicted instead of "a"
  assert_eq(c.get("a", now_ms=0L), Some(1))
  assert_eq(c.get("b", now_ms=0L), None)
  assert_eq(c.get("c", now_ms=0L), Some(3))
}

///|
test "an entry past its per-call ttl is treated as absent" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L, ttl_ms=10L)
  assert_eq(c.get("a", now_ms=9L), Some(1))
  assert_eq(c.get("a", now_ms=10L), None) // ttl is exclusive of the deadline
  assert_eq(c.stats().expirations, 1)
}

///|
test "a cache-wide default ttl applies when set doesn't override it" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(
    capacity=2,
    default_ttl_ms=5L,
  )
  c.set("a", 1, now_ms=0L)
  c.set("b", 2, now_ms=0L, ttl_ms=100L) // overrides the default for this entry
  assert_eq(c.get("a", now_ms=5L), None)
  assert_eq(c.get("b", now_ms=5L), Some(2))
}

///|
test "contains does not affect recency or counters" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=1)
  c.set("a", 1, now_ms=0L)
  assert_true(c.contains("a", now_ms=0L))
  assert_false(c.contains("b", now_ms=0L))
  assert_eq(c.stats(), { hits: 0, misses: 0, evictions: 0, expirations: 0, })
}

///|
test "remove returns the value once and then reports absence" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  assert_eq(c.remove("a"), Some(1))
  assert_eq(c.remove("a"), None)
  assert_eq(c.get("a", now_ms=0L), None)
}

///|
test "clear empties the cache and resets counters" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  ignore(c.get("a", now_ms=0L))
  ignore(c.get("missing", now_ms=0L))
  c.clear()
  assert_eq(c.size(), 0)
  assert_eq(c.stats(), { hits: 0, misses: 0, evictions: 0, expirations: 0, })
}

///|
test "purge_expired removes only entries past their deadline" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=4)
  c.set("a", 1, now_ms=0L, ttl_ms=10L)
  c.set("b", 2, now_ms=0L, ttl_ms=100L)
  c.set("c", 3, now_ms=0L)
  assert_eq(c.purge_expired(now_ms=10L), 1)
  assert_eq(c.size(), 2)
  assert_eq(c.stats().expirations, 1)
}

///|
test "get_or_insert_with computes once per miss and not again on a hit" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  let mut calls = 0
  fn compute() -> Int {
    calls += 1
    42
  }

  assert_eq(c.get_or_insert_with("a", now_ms=0L, compute), 42)
  assert_eq(c.get_or_insert_with("a", now_ms=1L, compute), 42)
  assert_eq(calls, 1)
}

///|
test "get_or_insert_with recomputes after the entry expires" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  let mut calls = 0
  fn compute() -> Int {
    calls += 1
    calls
  }

  assert_eq(c.get_or_insert_with("a", now_ms=0L, ttl_ms=10L, compute), 1)
  assert_eq(c.get_or_insert_with("a", now_ms=20L, ttl_ms=10L, compute), 2)
  assert_eq(calls, 2)
}

///|
test "peek reads a value without affecting recency or counters" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  c.set("b", 2, now_ms=0L)
  assert_eq(c.peek("a", now_ms=0L), Some(1))
  c.set("c", 3, now_ms=0L) // "a" was not touched by peek, so it's still LRU
  assert_eq(c.get("a", now_ms=0L), None)
  assert_eq(c.stats(), { hits: 0, misses: 1, evictions: 1, expirations: 0, })
}

///|
test "peek on an expired entry reads as absent but leaves it in place" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L, ttl_ms=10L)
  assert_eq(c.peek("a", now_ms=10L), None)
  assert_eq(c.size(), 1) // still present, just not surfaced by peek
}

///|
test "is_empty reflects presence of entries" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  assert_true(c.is_empty())
  c.set("a", 1, now_ms=0L)
  assert_false(c.is_empty())
  ignore(c.remove("a"))
  assert_true(c.is_empty())
}

///|
test "keys and values are ordered least- to most-recently-used" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=3)
  c.set("a", 1, now_ms=0L)
  c.set("b", 2, now_ms=0L)
  c.set("c", 3, now_ms=0L)
  assert_eq(c.keys().to_array(), ["a", "b", "c"])
  assert_eq(c.values().to_array(), [1, 2, 3])
  ignore(c.get("a", now_ms=0L)) // moves "a" to the most-recently-used end
  assert_eq(c.keys().to_array(), ["b", "c", "a"])
}

///|
test "to_array snapshots non-expired entries in LRU order" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=3)
  c.set("a", 1, now_ms=0L, ttl_ms=5L)
  c.set("b", 2, now_ms=0L)
  c.set("c", 3, now_ms=0L)
  assert_eq(c.to_array(now_ms=0L), [("a", 1), ("b", 2), ("c", 3)])
  // "a" has expired by now_ms=10, and to_array leaves it out without
  // removing it (unlike get/purge_expired, it doesn't mutate the cache).
  assert_eq(c.to_array(now_ms=10L), [("b", 2), ("c", 3)])
  assert_eq(c.size(), 3)
}

///|
test "retain drops entries that fail the predicate and keeps the rest" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=4)
  c.set("keep-a", 1, now_ms=0L)
  c.set("drop-a", 2, now_ms=0L)
  c.set("keep-b", 3, now_ms=0L)
  c.set("drop-b", 4, now_ms=0L)
  let removed = c.retain(fn(key, _value) { key.has_prefix("keep-") })
  assert_eq(removed, 2)
  assert_eq(c.size(), 2)
  assert_eq(c.get("keep-a", now_ms=0L), Some(1))
  assert_eq(c.get("keep-b", now_ms=0L), Some(3))
  assert_eq(c.get("drop-a", now_ms=0L), None)
}

///|
test "retain on a cache with nothing to drop removes zero entries" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  assert_eq(c.retain(fn(_key, _value) { true }), 0)
  assert_eq(c.size(), 1)
}

///|
test "capacity is reported back as given at construction" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=7)
  assert_eq(c.capacity(), 7)
}
