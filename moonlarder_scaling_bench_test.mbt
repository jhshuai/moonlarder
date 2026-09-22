///|
/// Benchmarks the real `Larder` against a deliberately naive LRU cache -
/// a plain array, linear-scanned and rebuilt on every operation, the
/// way a cache gets written before reaching for a `Map` - at growing
/// capacities. The real implementation's `Map`-backed O(1) design
/// should stay roughly flat as capacity grows; the naive one should
/// visibly degrade, since each of its operations costs O(capacity).
///
/// `it.bench` is given a shrinking `count` as capacity grows so total
/// work per benchmark stays roughly constant (and the naive variant
/// still finishes in reasonable time even at capacity 10,000) - the
/// absolute counts differ, but ratios between the two implementations
/// at the *same* capacity are the point, not raw numbers across rows.

///|
priv struct NaiveLru {
  mut order : Array[(Int, Int)] // oldest to newest
  capacity : Int
}

///|
fn NaiveLru::new(capacity : Int) -> NaiveLru {
  { order: [], capacity, }
}

///|
/// O(capacity): scans for `key`, and on a hit, rebuilds the array to
/// move it to the newest position - the naive equivalent of what
/// `Larder::touch` does in O(1) by just re-inserting into `Map`.
fn NaiveLru::get(self : NaiveLru, key : Int) -> Int? {
  let mut found : Int? = None
  for i = 0; i < self.order.length(); i = i + 1 {
    if self.order[i].0 == key {
      found = Some(self.order[i].1)
    }
  }
  match found {
    None => None
    Some(value) => {
      let rest = []
      for j = 0; j < self.order.length(); j = j + 1 {
        if self.order[j].0 != key {
          rest.push(self.order[j])
        }
      }
      rest.push((key, value))
      self.order = rest
      Some(value)
    }
  }
}

///|
/// O(capacity): rebuilds the array to remove any existing entry for
/// `key`, appends the new one, and trims the oldest entry (another
/// O(capacity) rebuild) if that pushed it over capacity.
fn NaiveLru::set(self : NaiveLru, key : Int, value : Int) -> Unit {
  let rest = []
  for j = 0; j < self.order.length(); j = j + 1 {
    if self.order[j].0 != key {
      rest.push(self.order[j])
    }
  }
  rest.push((key, value))
  if rest.length() > self.capacity {
    let trimmed = []
    for j = 1; j < rest.length(); j = j + 1 {
      trimmed.push(rest[j])
    }
    self.order = trimmed
  } else {
    self.order = rest
  }
}

///|
fn warm_naive(n : Int) -> NaiveLru {
  let cache = NaiveLru::new(n)
  for i = 0; i < n; i = i + 1 {
    cache.set(i, i)
  }
  cache
}

///|
test "bench get on a hit, capacity 100, real Larder" (it : @bench.T) {
  let cache = warm_cache(100)
  it.bench(fn() { it.keep(cache.get(50, now_ms=0L)) }, count=10_000)
}

///|
test "bench get on a hit, capacity 100, naive array scan" (it : @bench.T) {
  let cache = warm_naive(100)
  it.bench(fn() { it.keep(cache.get(50)) }, count=10_000)
}

///|
test "bench get on a hit, capacity 1,000, real Larder" (it : @bench.T) {
  let cache = warm_cache(1_000)
  it.bench(fn() { it.keep(cache.get(500, now_ms=0L)) }, count=1_000)
}

///|
test "bench get on a hit, capacity 1,000, naive array scan" (it : @bench.T) {
  let cache = warm_naive(1_000)
  it.bench(fn() { it.keep(cache.get(500)) }, count=1_000)
}

///|
test "bench get on a hit, capacity 10,000, real Larder" (it : @bench.T) {
  let cache = warm_cache(10_000)
  it.bench(fn() { it.keep(cache.get(5_000, now_ms=0L)) }, count=100)
}

///|
test "bench get on a hit, capacity 10,000, naive array scan" (it : @bench.T) {
  let cache = warm_naive(10_000)
  it.bench(fn() { it.keep(cache.get(5_000)) }, count=100)
}

///|
test "bench set at steady state, capacity 100, real Larder" (it : @bench.T) {
  let cache = warm_cache(100)
  let mut next_key = 100
  it.bench(
    fn() {
      cache.set(next_key, next_key, now_ms=0L)
      next_key += 1
    },
    count=10_000,
  )
}

///|
test "bench set at steady state, capacity 100, naive array scan" (it : @bench.T) {
  let cache = warm_naive(100)
  let mut next_key = 100
  it.bench(
    fn() {
      cache.set(next_key, next_key)
      next_key += 1
    },
    count=10_000,
  )
}

///|
test "bench set at steady state, capacity 1,000, real Larder" (it : @bench.T) {
  let cache = warm_cache(1_000)
  let mut next_key = 1_000
  it.bench(
    fn() {
      cache.set(next_key, next_key, now_ms=0L)
      next_key += 1
    },
    count=1_000,
  )
}

///|
test "bench set at steady state, capacity 1,000, naive array scan" (
  it : @bench.T,
) {
  let cache = warm_naive(1_000)
  let mut next_key = 1_000
  it.bench(
    fn() {
      cache.set(next_key, next_key)
      next_key += 1
    },
    count=1_000,
  )
}

///|
test "bench set at steady state, capacity 10,000, real Larder" (it : @bench.T) {
  let cache = warm_cache(10_000)
  let mut next_key = 10_000
  it.bench(
    fn() {
      cache.set(next_key, next_key, now_ms=0L)
      next_key += 1
    },
    count=100,
  )
}

///|
test "bench set at steady state, capacity 10,000, naive array scan" (
  it : @bench.T,
) {
  let cache = warm_naive(10_000)
  let mut next_key = 10_000
  it.bench(
    fn() {
      cache.set(next_key, next_key)
      next_key += 1
    },
    count=100,
  )
}
