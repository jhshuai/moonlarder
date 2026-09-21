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
test "touch_ttl extends an entry's deadline without changing its value" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L, ttl_ms=10L)
  assert_true(c.touch_ttl("a", now_ms=5L, ttl_ms=10L)) // now expires at 15, not 10
  assert_eq(c.get("a", now_ms=10L), Some(1))
  assert_eq(c.get("a", now_ms=15L), None)
}

///|
test "touch_ttl falls back to the cache-wide default ttl" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(
    capacity=2,
    default_ttl_ms=10L,
  )
  c.set("a", 1, now_ms=0L, ttl_ms=3L)
  assert_true(c.touch_ttl("a", now_ms=1L)) // now uses the 10ms default, not 3ms
  assert_eq(c.get("a", now_ms=3L), Some(1))
}

///|
test "touch_ttl on a missing or already-expired key returns false" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  assert_false(c.touch_ttl("missing", now_ms=0L))
  c.set("a", 1, now_ms=0L, ttl_ms=5L)
  assert_false(c.touch_ttl("a", now_ms=5L))
  assert_eq(c.size(), 0) // the expired entry was dropped, same as get() would
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
suberror LoadFailed {
  Reason(String)
}

///|
/// `try_get_or_insert_with`'s loader parameter must be typed to raise, so
/// these two helpers exist even for the tests that only exercise the
/// success path - a top-level function, unlike a test-local closure, can
/// carry the pragma that says so deliberately.
#warnings("-unused_error_type")
fn succeed(value : Int) -> Int raise LoadFailed {
  value
}

///|
#warnings("-unused_error_type")
fn succeed_and_count(calls : Array[Int], value : Int) -> Int raise LoadFailed {
  calls[0] = calls[0] + 1
  value
}

///|
test "try_get_or_insert_with returns the loaded value on success" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  let value = c.try_get_or_insert_with("a", now_ms=0L, () => succeed(42))
  assert_eq(value, 42)
  assert_eq(c.get("a", now_ms=0L), Some(42))
}

///|
test "try_get_or_insert_with propagates a loader's error and stores nothing" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  try {
    let _ = c.try_get_or_insert_with("a", now_ms=0L, fn() -> Int raise LoadFailed {
      raise Reason("boom")
    })
    fail("expected try_get_or_insert_with to propagate the loader's error")
  } catch {
    Reason(msg) => assert_eq(msg, "boom")
    _ => fail("expected LoadFailed::Reason")
  }
  assert_false(c.contains("a", now_ms=0L))
}

///|
test "try_get_or_insert_with does not call compute again on a hit" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  let calls = [0]
  ignore(
    c.try_get_or_insert_with("a", now_ms=0L, () => succeed_and_count(calls, 42)),
  )
  ignore(
    c.try_get_or_insert_with("a", now_ms=1L, () => succeed_and_count(calls, 42)),
  )
  assert_eq(calls[0], 1)
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

///|
test "resize upward does not evict" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=2)
  c.set("a", 1, now_ms=0L)
  c.set("b", 2, now_ms=0L)
  c.resize(5)
  assert_eq(c.capacity(), 5)
  assert_eq(c.size(), 2)
  assert_eq(c.stats().evictions, 0)
}

///|
test "resize downward evicts the least-recently-used entries immediately" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=4)
  c.set("a", 1, now_ms=0L)
  c.set("b", 2, now_ms=0L)
  c.set("c", 3, now_ms=0L)
  c.set("d", 4, now_ms=0L)
  c.resize(2)
  assert_eq(c.size(), 2)
  assert_eq(c.stats().evictions, 2)
  assert_eq(c.get("a", now_ms=0L), None)
  assert_eq(c.get("b", now_ms=0L), None)
  assert_eq(c.get("c", now_ms=0L), Some(3))
  assert_eq(c.get("d", now_ms=0L), Some(4))
}

///|
test "an unweighted cache treats capacity as an entry count" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=3)
  c.set("a", 1, now_ms=0L)
  assert_eq(c.weight(), 1)
  assert_eq(c.weight(), c.size())
}

///|
test "a weigher turns capacity into a weight budget" {
  let c : @moonlarder.Larder[String, String] = @moonlarder.Larder::new(
    capacity=10,
    weigher=fn(_key, value : String) { value.length() },
  )
  c.set("a", "12345", now_ms=0L) // weight 5
  c.set("b", "123", now_ms=0L) // weight 3, total 8
  assert_eq(c.weight(), 8)
  assert_eq(c.size(), 2)
  assert_eq(c.stats().evictions, 0)
  c.set("c", "1234", now_ms=0L) // weight 4, total would be 12 > 10
  // "a" is least-recently-used, so it goes; that alone (8 - 5 + 4 = 7)
  // is already back within budget.
  assert_eq(c.weight(), 7)
  assert_eq(c.get("a", now_ms=0L), None)
  assert_eq(c.get("b", now_ms=0L), Some("123"))
  assert_eq(c.get("c", now_ms=0L), Some("1234"))
}

///|
test "a single entry heavier than capacity is admitted alone" {
  let c : @moonlarder.Larder[String, String] = @moonlarder.Larder::new(
    capacity=5,
    weigher=fn(_key, value : String) { value.length() },
  )
  c.set("small", "ab", now_ms=0L)
  c.set("huge", "0123456789", now_ms=0L) // weight 10, alone already over capacity
  assert_eq(c.size(), 1)
  assert_eq(c.weight(), 10)
  assert_eq(c.get("small", now_ms=0L), None)
  assert_eq(c.get("huge", now_ms=0L), Some("0123456789"))
}

///|
test "updating a weighted key's value adjusts total weight in place" {
  let c : @moonlarder.Larder[String, String] = @moonlarder.Larder::new(
    capacity=10,
    weigher=fn(_key, value : String) { value.length() },
  )
  c.set("a", "12345", now_ms=0L) // weight 5
  c.set("a", "12", now_ms=0L) // weight 2, replacing the old one, not adding
  assert_eq(c.weight(), 2)
  assert_eq(c.size(), 1)
}

///|
test "resize honors a weigher's budget, not entry count" {
  let c : @moonlarder.Larder[String, String] = @moonlarder.Larder::new(
    capacity=20,
    weigher=fn(_key, value : String) { value.length() },
  )
  c.set("a", "12345", now_ms=0L) // weight 5
  c.set("b", "12345", now_ms=0L) // weight 5, total 10
  c.resize(6)
  assert_eq(c.size(), 1)
  assert_eq(c.weight(), 5)
  assert_eq(c.get("a", now_ms=0L), None)
  assert_eq(c.get("b", now_ms=0L), Some("12345"))
}

///|
test "Show for Larder summarizes size, capacity, and weight" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=10)
  c.set("a", 1, now_ms=0L)
  c.set("b", 2, now_ms=0L)
  assert_eq(c.to_string(), "Larder(size=2, capacity=10, weight=2)")
}

///|
test "Debug for Larder matches its Show output" {
  let c : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(capacity=10)
  c.set("a", 1, now_ms=0L)
  debug_inspect(c, content="Larder(size=1, capacity=10, weight=1)")
}
