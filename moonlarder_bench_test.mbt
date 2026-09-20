///|
/// A cache with `n` entries already inserted, none of them expiring on
/// their own - useful as a fixed starting point for benchmarks that
/// shouldn't measure eviction or expiry themselves.
fn warm_cache(n : Int) -> @moonlarder.Larder[Int, Int] {
  let cache : @moonlarder.Larder[Int, Int] = @moonlarder.Larder::new(capacity=n)
  for i = 0; i < n; i = i + 1 {
    cache.set(i, i, now_ms=0L)
  }
  cache
}

///|
test "bench get on a hit" (it : @bench.T) {
  let cache = warm_cache(1000)
  it.bench(fn() { it.keep(cache.get(500, now_ms=0L)) })
}

///|
test "bench get on a miss" (it : @bench.T) {
  let cache = warm_cache(1000)
  it.bench(fn() { it.keep(cache.get(-1, now_ms=0L)) })
}

///|
test "bench set at steady state (every insert evicts one)" (it : @bench.T) {
  let cache = warm_cache(1000)
  let mut next_key = 1000
  it.bench(fn() {
    cache.set(next_key, next_key, now_ms=0L)
    next_key += 1
  })
}

///|
test "bench get_or_insert_with on a hit" (it : @bench.T) {
  let cache = warm_cache(1000)
  it.bench(fn() {
    it.keep(cache.get_or_insert_with(500, now_ms=0L, fn() { -1 }))
  })
}
