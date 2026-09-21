///|
/// Property-based tests. Rather than hand-picked scenarios, these replay
/// a randomly generated sequence of operations - `(kind, key, value)`
/// triples, with `kind` and `key` folded into small ranges so keys
/// collide often enough to actually exercise eviction - against the real
/// `Larder` and check invariants that must hold no matter what sequence
/// produced the current state.
///
/// `LruModel` and `LfuModel` below are deliberately naive, independent
/// reference implementations (plain arrays, linear scans, no `Map`, no
/// frequency buckets) used only to differentially test the real
/// `Map`-based O(1)-amortized implementations against something simple
/// enough to trust by inspection.

///|
priv struct LruModel {
  mut order : Array[Int] // oldest to newest
  capacity : Int
}

///|
fn LruModel::new(capacity : Int) -> LruModel {
  { order: [], capacity, }
}

///|
/// Moves `key` to the newest position, inserting it if absent, and
/// trims the oldest entry if that insertion pushed the model over
/// capacity.
fn LruModel::bump(self : LruModel, key : Int) -> Unit {
  self.order = self.order.filter(fn(k) { k != key })
  self.order.push(key)
  if self.order.length() > self.capacity {
    let trimmed = []
    for i = 1; i < self.order.length(); i = i + 1 {
      trimmed.push(self.order[i])
    }
    self.order = trimmed
  }
}

///|
fn LruModel::get(self : LruModel, key : Int) -> Bool {
  if self.order.contains(key) {
    self.bump(key)
    true
  } else {
    false
  }
}

///|
fn LruModel::set(self : LruModel, key : Int) -> Unit {
  self.bump(key)
}

///|
priv struct LfuModel {
  mut keys : Array[Int] // oldest- to newest-touched
  mut freqs : Array[Int] // freqs[i] is keys[i]'s access count
  capacity : Int
}

///|
fn LfuModel::new(capacity : Int) -> LfuModel {
  { keys: [], freqs: [], capacity, }
}

///|
fn LfuModel::index_of(self : LfuModel, key : Int) -> Int? {
  for i = 0; i < self.keys.length(); i = i + 1 {
    if self.keys[i] == key {
      return Some(i)
    }
  }
  None
}

///|
/// Drops the entry at `index` from both parallel arrays.
fn LfuModel::drop_at(self : LfuModel, index : Int) -> Unit {
  let new_keys = []
  let new_freqs = []
  for j = 0; j < self.keys.length(); j = j + 1 {
    if j != index {
      new_keys.push(self.keys[j])
      new_freqs.push(self.freqs[j])
    }
  }
  self.keys = new_keys
  self.freqs = new_freqs
}

///|
/// Increments an already-present key's frequency and moves it to the
/// newest position - since both arrays stay in overall recency order,
/// the first (leftmost) entry among any frequency value is always the
/// least-recently-touched one at that frequency, which is exactly the
/// tie-break `evict` relies on below.
fn LfuModel::bump(self : LfuModel, key : Int) -> Unit {
  match self.index_of(key) {
    Some(i) => {
      let freq = self.freqs[i] + 1
      self.drop_at(i)
      self.keys.push(key)
      self.freqs.push(freq)
    }
    None => ()
  }
}

///|
fn LfuModel::get(self : LfuModel, key : Int) -> Bool {
  match self.index_of(key) {
    Some(_) => {
      self.bump(key)
      true
    }
    None => false
  }
}

///|
fn LfuModel::set(self : LfuModel, key : Int) -> Unit {
  match self.index_of(key) {
    Some(_) => self.bump(key)
    None => {
      self.keys.push(key)
      self.freqs.push(1)
      if self.keys.length() > self.capacity {
        let mut min_index = 0
        let mut min_freq = self.freqs[0]
        for i = 1; i < self.freqs.length(); i = i + 1 {
          if self.freqs[i] < min_freq {
            min_freq = self.freqs[i]
            min_index = i
          }
        }
        self.drop_at(min_index)
      }
    }
  }
}

///|
/// Folds a raw generated triple into a small, collision-prone key so
/// eviction and re-access actually get exercised (a raw arbitrary `Int`
/// key would almost never repeat).
fn fold_key(raw : Int) -> Int {
  raw.abs() % 6
}

///|
fn prop_lru_matches_naive_model(ops : Array[(Int, Int, Int)]) -> Bool {
  let capacity = 4
  let cache : @moonlarder.Larder[Int, Int] = @moonlarder.Larder::new(capacity~)
  let model = LruModel::new(capacity)
  for op in ops {
    let (kind, raw_key, value) = op
    let key = fold_key(raw_key)
    if kind % 3 == 2 {
      let expected = model.get(key)
      let actual = match cache.get(key, now_ms=0L) {
        Some(_) => true
        None => false
      }
      if expected != actual {
        return false
      }
    } else {
      model.set(key)
      cache.set(key, value, now_ms=0L)
    }
  }
  cache.keys().to_array() == model.order
}

///|
fn prop_lfu_matches_naive_model(ops : Array[(Int, Int, Int)]) -> Bool {
  let capacity = 4
  let cache : @moonlarder.Larder[Int, Int] = @moonlarder.Larder::new(
    capacity~,
    policy=@moonlarder.Lfu,
  )
  let model = LfuModel::new(capacity)
  for op in ops {
    let (kind, raw_key, value) = op
    let key = fold_key(raw_key)
    if kind % 3 == 2 {
      let expected = model.get(key)
      let actual = match cache.get(key, now_ms=0L) {
        Some(_) => true
        None => false
      }
      if expected != actual {
        return false
      }
    } else {
      model.set(key)
      cache.set(key, value, now_ms=0L)
    }
  }
  let cache_keys = cache.keys().to_array()
  if cache_keys.length() != model.keys.length() {
    return false
  }
  for key in model.keys {
    if !cache_keys.contains(key) {
      return false
    }
  }
  true
}

///|
/// `weight() <= capacity()` must hold after any sequence of operations,
/// except immediately after inserting a single entry heavier than
/// capacity on its own (`size() <= 1` in that case) - the same
/// exception `new`'s and `set`'s own doc comments describe.
fn prop_capacity_is_never_exceeded(ops : Array[(Int, Int, Int)]) -> Bool {
  let capacity = 5
  let cache : @moonlarder.Larder[Int, Int] = @moonlarder.Larder::new(capacity~)
  for op in ops {
    let (kind, raw_key, value) = op
    let key = fold_key(raw_key)
    match kind % 4 {
      0 => ignore(cache.get(key, now_ms=0L))
      1 => cache.set(key, value, now_ms=0L)
      2 => ignore(cache.remove(key))
      _ => ignore(cache.retain(fn(k, _v) { k != key }))
    }
    if cache.weight() > cache.capacity() && cache.size() > 1 {
      return false
    }
  }
  true
}

///|
/// Every entry `to_array` reports present must actually be gettable
/// (via `peek`, so the check itself doesn't disturb recency) with the
/// exact value `to_array` reported.
fn prop_to_array_agrees_with_peek(ops : Array[(Int, Int, Int)]) -> Bool {
  let capacity = 5
  let cache : @moonlarder.Larder[Int, Int] = @moonlarder.Larder::new(capacity~)
  for op in ops {
    let (kind, raw_key, value) = op
    let key = fold_key(raw_key)
    match kind % 3 {
      0 => ignore(cache.get(key, now_ms=0L))
      1 => cache.set(key, value, now_ms=0L)
      _ => ignore(cache.remove(key))
    }
  }
  for entry in cache.to_array(now_ms=0L) {
    if cache.peek(entry.0, now_ms=0L) != Some(entry.1) {
      return false
    }
  }
  true
}

///|
/// `from_json(to_json(cache))` must be indistinguishable from `cache`
/// itself for every non-expired entry present at the moment of the
/// snapshot - not bit-for-bit identical (LRU recency order, LFU
/// frequencies, and TTLs are all deliberately not part of the JSON
/// shape), just the same set of keys mapping to the same values.
fn prop_json_round_trip_preserves_contents(
  ops : Array[(Int, Int, Int)],
) -> Bool {
  let capacity = 5
  let cache : @moonlarder.Larder[Int, Int] = @moonlarder.Larder::new(capacity~)
  for op in ops {
    let (kind, raw_key, value) = op
    let key = fold_key(raw_key)
    match kind % 3 {
      0 => ignore(cache.get(key, now_ms=0L))
      1 => cache.set(key, value, now_ms=0L)
      _ => ignore(cache.remove(key))
    }
  }
  try {
    let restored : @moonlarder.Larder[Int, Int] = @json.from_json(
      ToJson::to_json(cache),
    )
    if restored.size() != cache.size() {
      false
    } else {
      let mut ok = true
      for entry in cache.to_array(now_ms=0L) {
        if restored.peek(entry.0, now_ms=0L) != Some(entry.1) {
          ok = false
        }
      }
      ok
    }
  } catch {
    // A snapshot this test just produced itself failing to parse back
    // would be a real bug, not something to silently ignore.
    _ => false
  }
}

///|
test "property: LRU matches an independent naive reference model" {
  @quickcheck.quick_check_fn(prop_lru_matches_naive_model)
}

///|
test "property: LFU matches an independent naive reference model" {
  @quickcheck.quick_check_fn(prop_lfu_matches_naive_model)
}

///|
test "property: capacity is never exceeded except by a single oversized entry" {
  @quickcheck.quick_check_fn(prop_capacity_is_never_exceeded)
}

///|
test "property: to_array's report always agrees with peek" {
  @quickcheck.quick_check_fn(prop_to_array_agrees_with_peek)
}

///|
test "property: a JSON round trip preserves every live entry" {
  @quickcheck.quick_check_fn(prop_json_round_trip_preserves_contents)
}
