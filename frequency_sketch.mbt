///|
/// An approximate, constant-space "how many times have I seen this
/// key?" counter - a Count-Min Sketch (Cormode and Muthukrishnan, "An
/// Improved Data Stream Summary: The Count-Min Sketch and its
/// Applications", 2005), sized and aged the way Einziger, Friedman, and
/// Manes' TinyLFU ("TinyLFU: A Highly Efficient Cache Admission
/// Policy", ACM TOS 2017) uses one to decide whether a cache candidate
/// deserves to displace an existing entry - see `Larder::new`'s
/// `admission_filter?` parameter for that use.
///
/// Unlike an exact `Map[K, Int]`, `estimate` can overestimate a key's
/// count (two keys colliding in the same counter inflate each other)
/// but never underestimates it, and space stays fixed regardless of
/// how many distinct keys are ever seen - the trade this data
/// structure is for. Counts are also deliberately short-lived: a
/// 4-bit-equivalent cap per counter (0-15) plus periodic halving of
/// the whole table keeps `estimate` reflecting *recent* frequency
/// rather than accumulating forever, which is what a cache admission
/// decision actually wants ("was this popular lately", not "was this
/// ever popular once, years ago").
///
/// `K` only needs `Hash`, not `Eq` - a sketch never stores or compares
/// keys directly, only the positions their hashes land on. `K` itself
/// doesn't appear in any field (the table is a plain `Array[Int]`), so
/// it's a phantom type parameter here purely to keep a sketch tied to
/// the one key type it was sized and hashed for, the same way it's
/// tied to a single `Larder[K, V]` when used as that cache's admission
/// filter.
#warnings("-unused_type_variable")
pub struct FrequencySketch[K] {
  // 4 independent rows of `width` saturating counters (0-15 each),
  // stored as one row after another: row r's counter for key `key`
  // lives at `row_index(r, key) + r * width`. 4 rows (rather than 1)
  // is what makes this a *count-min* sketch: taking the min across
  // independently-hashed rows cancels out most single-row collisions.
  table : Array[Int]
  width : Int
  mut additions : Int
  sample_size : Int
}

///|
/// Four fixed, distinct seeds - one per row - so a single `K : Hash`
/// gives four decorrelated-enough hash values instead of needing four
/// separate hash functions from the caller.
let row_seeds : Array[Int] = [0, 1, 2, 3]

///|
const MAX_COUNTER : Int = 15

///|
/// Creates an empty sketch sized for roughly `capacity` distinct keys
/// - typically the same `capacity` as the `Larder` it's protecting.
/// `capacity` is a sizing hint, not a hard limit: a sketch never
/// rejects a key for being "too many", it just gets proportionally
/// less accurate (more collisions) the further usage grows past it.
pub fn[K] FrequencySketch::new(capacity~ : Int) -> FrequencySketch[K] {
  guard capacity > 0 else {
    abort("FrequencySketch::new: capacity must be positive, got \{capacity}")
  }
  let width = (capacity * 4).max(16)
  {
    table: Array::make(width * 4, 0),
    width,
    additions: 0,
    sample_size: width * 10,
  }
}

///|
fn[K : Hash] FrequencySketch::row_index(
  self : FrequencySketch[K],
  row : Int,
  key : K,
) -> Int {
  let hasher = Hasher(seed=row_seeds[row])
  hasher.combine(key)
  let raw = hasher.finalize()
  (raw & 0x7fffffff) % self.width + row * self.width
}

///|
/// Records one more occurrence of `key`. Ages the whole table (halving
/// every counter) once total `increment` calls since the last aging
/// reach roughly ten times the table's width - the standard TinyLFU
/// heuristic for keeping estimates weighted toward recent activity
/// instead of growing without bound.
pub fn[K : Hash] FrequencySketch::increment(
  self : FrequencySketch[K],
  key : K,
) -> Unit {
  for row = 0; row < 4; row = row + 1 {
    let idx = self.row_index(row, key)
    if self.table[idx] < MAX_COUNTER {
      self.table[idx] += 1
    }
  }
  self.additions += 1
  if self.additions >= self.sample_size {
    self.age()
  }
}

///|
fn[K] FrequencySketch::age(self : FrequencySketch[K]) -> Unit {
  for i = 0; i < self.table.length(); i = i + 1 {
    self.table[i] = self.table[i] / 2
  }
  self.additions = self.additions / 2
}

///|
/// An approximate count of how many times `increment(key)` has been
/// called since the sketch was created or last aged - never lower than
/// the true count while counters are unsaturated (`<= 15`), possibly
/// higher if `key` collides with other keys in a row's counters. The
/// four rows' counters are combined by taking the minimum, which is
/// what keeps a single unlucky collision from inflating the estimate
/// as much as an ordinary hash table would.
pub fn[K : Hash] FrequencySketch::estimate(
  self : FrequencySketch[K],
  key : K,
) -> Int {
  let mut result = MAX_COUNTER
  for row = 0; row < 4; row = row + 1 {
    let idx = self.row_index(row, key)
    result = result.min(self.table[idx])
  }
  result
}

///|
/// Resets every counter to zero, as if the sketch were freshly
/// created. Unlike the automatic periodic aging `increment` performs
/// (which halves counts to keep them recent-weighted), this clears
/// everything at once - the counterpart to `Larder::clear()`.
pub fn[K] FrequencySketch::clear(self : FrequencySketch[K]) -> Unit {
  for i = 0; i < self.table.length(); i = i + 1 {
    self.table[i] = 0
  }
  self.additions = 0
}

///|
pub impl[K] Show for FrequencySketch[K] with fn output(self, logger) {
  logger.write_string(
    "FrequencySketch(width=\{self.width}, additions=\{self.additions})",
  )
}

///|
pub impl[K] @moonbitlang/core/debug.Debug for FrequencySketch[K] with fn to_repr(
  self,
) {
  @moonbitlang/core/debug.Repr::literal(self.to_string())
}

///|
pub extend FrequencySketch with Show::{to_string, output}

///|
pub extend FrequencySketch with @moonbitlang/core/debug.Debug::{to_repr}
