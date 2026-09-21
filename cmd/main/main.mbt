///|
/// A runnable tour of `moonlarder`, covering LRU eviction, TTL expiry,
/// memoization, weighted capacity, the LFU eviction policy, and JSON
/// snapshotting. Every step uses an explicit `now_ms` rather than a
/// real clock, on purpose: `Larder` never reads time on its own, so
/// this program's behavior is exactly reproducible on every target
/// `moon run cmd/main` can build for.
fn main {
  println(
    "moonlarder -- a generic in-memory cache with LRU/LFU eviction, TTL, and JSON snapshots",
  )
  demo_lru()
  demo_ttl()
  demo_memoize()
  demo_weighted()
  demo_lfu()
  demo_json()
}

///|
fn demo_lru() -> Unit {
  println("\n== LRU eviction ==")
  let cache : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(
    capacity=3,
  )
  cache.set("a", 1, now_ms=0L)
  cache.set("b", 2, now_ms=0L)
  cache.set("c", 3, now_ms=0L)
  println("inserted \"a\", \"b\", \"c\" into a capacity-3 cache: \{cache}")
  ignore(cache.get("a", now_ms=0L))
  println("touched \"a\", making it the most-recently-used")
  cache.set("d", 4, now_ms=0L)
  println("inserted \"d\": \{cache}")
  let b = @moonbitlang/core/debug.to_string(cache.get("b", now_ms=0L))
  println(
    "\"b\" was the least-recently-used, so it's the one that got evicted: get(\"b\") = \{b}",
  )
  let survivors = @moonbitlang/core/debug.to_string(cache.to_array(now_ms=0L))
  println("\"a\", \"c\", \"d\" all survive: \{survivors}")
}

///|
fn demo_ttl() -> Unit {
  println("\n== TTL expiry ==")
  let cache : @moonlarder.Larder[String, String] = @moonlarder.Larder::new(
    capacity=10,
    default_ttl_ms=5_000L,
  )
  cache.set("session:alice", "logged in", now_ms=0L)
  println("set \"session:alice\" at t=0 with the cache's 5s default TTL")
  let before_deadline = @moonbitlang/core/debug.to_string(
    cache.get("session:alice", now_ms=4_999L),
  )
  println("at t=4999ms: get(\"session:alice\") = \{before_deadline}")
  let at_deadline = @moonbitlang/core/debug.to_string(
    cache.get("session:alice", now_ms=5_000L),
  )
  println("at t=5000ms: get(\"session:alice\") = \{at_deadline}")
}

///|
fn demo_memoize() -> Unit {
  println("\n== Memoization ==")
  let cache : @moonlarder.Larder[Int, Int] = @moonlarder.Larder::new(
    capacity=10,
  )
  let mut calls = 0
  fn expensive_square(n : Int) -> Int {
    calls += 1
    n * n
  }

  let first = cache.get_or_insert_with(7, now_ms=0L, fn() {
    expensive_square(7)
  })
  let second = cache.get_or_insert_with(7, now_ms=1L, fn() {
    expensive_square(7)
  })
  println(
    "get_or_insert_with(7) called twice -> \{first}, \{second}, but the loader ran \{calls} time(s)",
  )
}

///|
fn demo_weighted() -> Unit {
  println("\n== Weighted capacity ==")
  let cache : @moonlarder.Larder[String, String] = @moonlarder.Larder::new(
    capacity=15,
    weigher=fn(_key, value : String) { value.length() },
  )
  cache.set("short", "hi", now_ms=0L)
  cache.set("long", "0123456789", now_ms=0L)
  let weight = cache.weight()
  let capacity = cache.capacity()
  println(
    "after \"short\" (weight 2) and \"long\" (weight 10): weight = \{weight} / capacity \{capacity} - both fit",
  )
  cache.set("more", "abcabc", now_ms=0L)
  println(
    "inserting \"more\" (weight 6) pushes total weight to 18, over capacity 15:",
  )
  println("  \{cache}")
  let survivors = @moonbitlang/core/debug.to_string(cache.to_array(now_ms=0L))
  println("  survivors: \{survivors}")
}

///|
fn demo_lfu() -> Unit {
  println("\n== LFU vs LRU ==")
  let cache : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(
    capacity=2,
    policy=Lfu,
  )
  cache.set("popular", 1, now_ms=0L)
  cache.set("one-hit-wonder", 2, now_ms=0L)
  ignore(cache.get("popular", now_ms=0L))
  ignore(cache.get("popular", now_ms=0L))
  println("\"popular\" used 3 times total; \"one-hit-wonder\" used once")
  cache.set("newcomer", 3, now_ms=0L)
  println("inserting \"newcomer\" (capacity 2, so something evicts): \{cache}")
  let one_hit_wonder = @moonbitlang/core/debug.to_string(
    cache.get("one-hit-wonder", now_ms=0L),
  )
  println(
    "\"one-hit-wonder\" was the least-frequently-used, so it's gone even though it's more recent than \"popular\": get(\"one-hit-wonder\") = \{one_hit_wonder}",
  )
  let popular = @moonbitlang/core/debug.to_string(
    cache.get("popular", now_ms=0L),
  )
  println(
    "\"popular\" survives on frequency alone: get(\"popular\") = \{popular}",
  )
}

///|
fn demo_json() -> Unit {
  println("\n== JSON snapshot ==")
  let cache : @moonlarder.Larder[String, Int] = @moonlarder.Larder::new(
    capacity=5,
  )
  cache.set("a", 1, now_ms=0L)
  cache.set("b", 2, now_ms=0L)
  let text = ToJson::to_json(cache).stringify(indent=2)
  println("serialized:")
  println(text)
  try {
    let restored : @moonlarder.Larder[String, Int] = @json.from_json(
      @json.parse(text),
    )
    let a = @moonbitlang/core/debug.to_string(restored.get("a", now_ms=0L))
    println("reloaded from that text: \{restored}, get(\"a\") = \{a}")
  } catch {
    error =>
      println(
        "failed to reload the snapshot (this would be a real bug): \{error}",
      )
  }
}
