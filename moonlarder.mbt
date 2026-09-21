///|
/// A bounded, expiring in-memory cache.
///
/// Entries beyond `capacity` are evicted least-recently-used first, and an
/// entry older than its time-to-live is treated as absent the next time it
/// is looked up. The clock is supplied by the caller on every call that
/// needs one (`now_ms`) instead of being read internally, so behavior stays
/// deterministic and testable regardless of target or wall-clock source.
///
/// By default `capacity` counts entries (every entry weighs 1). Pass
/// `weigher` to `new` to have it count something else instead - total
/// byte size, say, for a cache of blobs where a handful of large ones
/// shouldn't crowd out many small ones the way plain entry-counting
/// would let them.
pub struct Larder[K, V] {
  table : Map[K, Slot[V]]
  mut capacity : Int
  default_ttl_ms : Int64?
  weigher : (K, V) -> Int
  mut current_weight : Int
  mut hit_count : Int
  mut miss_count : Int
  mut eviction_count : Int
  mut expiration_count : Int
}

///|
pub struct Slot[V] {
  value : V
  expire_at : Int64? // None means the entry never expires on its own
  weight : Int // cached at insertion time so eviction never recomputes it
}

///|
/// A snapshot of a cache's counters since it was created or last cleared.
pub(all) struct Stats {
  hits : Int
  misses : Int
  evictions : Int
  expirations : Int
} derive(Eq, Debug)

///|
pub extend Stats with Eq::{not_equal, equal}

///|
pub extend Stats with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Prints as `Larder(size=.., capacity=.., weight=..)` - a structural
/// summary, not a dump of every key and value. Larger caches make a full
/// dump impractical to read, and a cache's entries may not even be worth
/// printing (nothing here requires `K`/`V` to implement `Show`).
pub impl[K, V] Show for Larder[K, V] with fn output(self, logger) {
  logger.write_string(
    "Larder(size=\{self.table.length()}, capacity=\{self.capacity}, weight=\{self.current_weight})",
  )
}

///|
pub impl[K, V] @moonbitlang/core/debug.Debug for Larder[K, V] with fn to_repr(
  self,
) {
  @moonbitlang/core/debug.Repr::literal(self.to_string())
}

///|
pub extend Larder with Show::{to_string, output}

///|
pub extend Larder with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Creates an empty cache bounded by `capacity`.
///
/// `default_ttl_ms`, when given, is the time-to-live applied to entries
/// that don't specify their own via `set`'s `ttl_ms` argument. Leaving both
/// unset means an entry never expires on its own and is only removed by
/// LRU eviction, `remove`, or `clear`.
///
/// `weigher`, when given, turns `capacity` into a weight budget rather
/// than a plain entry count: each entry contributes `weigher(key,
/// value)` instead of 1. An entry whose own weight exceeds `capacity` is
/// still admitted alone (evicting everything else) rather than being
/// rejected, since `set` never fails.
pub fn[K : Hash + Eq, V] Larder::new(
  capacity~ : Int,
  default_ttl_ms? : Int64,
  weigher? : (K, V) -> Int,
) -> Larder[K, V] {
  guard capacity > 0 else {
    abort("Larder::new: capacity must be positive, got \{capacity}")
  }
  {
    table: {},
    capacity,
    default_ttl_ms,
    weigher: match weigher {
      Some(weigher) => weigher
      None => fn(_key, _value) { 1 }
    },
    current_weight: 0,
    hit_count: 0,
    miss_count: 0,
    eviction_count: 0,
    expiration_count: 0,
  }
}

///|
/// Builds a cache from `entries` in one call, as if `set` had been
/// called for each in order - so later entries end up more
/// recently-used than earlier ones, and capacity/weight limits are
/// enforced the same way, possibly evicting some of `entries` itself if
/// they don't all fit.
///
/// The usual reason to reach for this instead of a loop of `set` calls
/// is rehydrating a cache from persisted state (a snapshot written by
/// `to_array`, say) in one expression rather than several statements.
pub fn[K : Hash + Eq, V] Larder::from_array(
  entries : Array[(K, V)],
  capacity~ : Int,
  default_ttl_ms? : Int64,
  weigher? : (K, V) -> Int,
  now_ms~ : Int64,
) -> Larder[K, V] {
  let cache = Larder::new(capacity~, default_ttl_ms?, weigher?)
  for entry in entries {
    cache.set(entry.0, entry.1, now_ms~)
  }
  cache
}

///|
fn[V] Slot::is_expired(self : Slot[V], now_ms : Int64) -> Bool {
  match self.expire_at {
    None => false
    Some(deadline) => now_ms >= deadline
  }
}

///|
fn[K, V] Larder::resolve_expiry(
  self : Larder[K, V],
  now_ms : Int64,
  ttl_ms : Int64?,
) -> Int64? {
  match ttl_ms {
    Some(ttl) => Some(now_ms + ttl)
    None =>
      match self.default_ttl_ms {
        Some(ttl) => Some(now_ms + ttl)
        None => None
      }
  }
}

///|
/// Moves an already-present key to the most-recently-used position.
///
/// `Map` preserves insertion order and does not reorder a key on `set`, so
/// recency is tracked by removing and re-inserting the entry.
fn[K : Hash + Eq, V] Larder::touch(
  self : Larder[K, V],
  key : K,
  slot : Slot[V],
) -> Unit {
  self.table.remove(key)
  self.table.set(key, slot)
}

///|
/// Evicts the least-recently-used entry, if any, without touching stats
/// other than `eviction_count`.
fn[K : Hash + Eq, V] Larder::evict_oldest(self : Larder[K, V]) -> Unit {
  for key, slot in self.table {
    self.table.remove(key)
    self.current_weight -= slot.weight
    self.eviction_count += 1
    break
  }
}

///|
/// Evicts least-recently-used entries until `current_weight` is back
/// within `capacity`, always leaving at least one entry in place so a
/// single entry heavier than `capacity` doesn't evict itself.
fn[K : Hash + Eq, V] Larder::enforce_capacity(self : Larder[K, V]) -> Unit {
  while self.current_weight > self.capacity && self.table.length() > 1 {
    self.evict_oldest()
  }
}

///|
/// Removes an entry already known to be expired, on the lazy-expiry path
/// shared by `get` and `touch_ttl`.
fn[K : Hash + Eq, V] Larder::drop_expired(
  self : Larder[K, V],
  key : K,
  slot : Slot[V],
) -> Unit {
  self.table.remove(key)
  self.current_weight -= slot.weight
  self.expiration_count += 1
}

///|
/// Looks up `key`, returning `None` if it is absent or has expired.
///
/// A hit refreshes the entry's recency; an expired entry is dropped from
/// the cache as a side effect of the lookup (lazy expiry) and counted as
/// both a miss and an expiration.
pub fn[K : Hash + Eq, V] Larder::get(
  self : Larder[K, V],
  key : K,
  now_ms~ : Int64,
) -> V? {
  match self.table.get(key) {
    None => {
      self.miss_count += 1
      None
    }
    Some(slot) =>
      if slot.is_expired(now_ms) {
        self.drop_expired(key, slot)
        self.miss_count += 1
        None
      } else {
        self.touch(key, slot)
        self.hit_count += 1
        Some(slot.value)
      }
  }
}

///|
/// Returns whether `key` is present and not expired, without affecting
/// recency or hit/miss counters.
pub fn[K : Hash + Eq, V] Larder::contains(
  self : Larder[K, V],
  key : K,
  now_ms~ : Int64,
) -> Bool {
  match self.table.get(key) {
    None => false
    Some(slot) => !slot.is_expired(now_ms)
  }
}

///|
/// Reads `key` without affecting recency or hit/miss counters.
///
/// Use this for inspection and debugging where `get`'s side effects
/// (marking the entry most-recently-used, counting a hit or miss) would
/// be misleading. An expired entry still reads as `None`, but unlike
/// `get` it is left in place rather than removed.
pub fn[K : Hash + Eq, V] Larder::peek(
  self : Larder[K, V],
  key : K,
  now_ms~ : Int64,
) -> V? {
  match self.table.get(key) {
    None => None
    Some(slot) => if slot.is_expired(now_ms) { None } else { Some(slot.value) }
  }
}

///|
/// Whether the cache holds no entries.
pub fn[K, V] Larder::is_empty(self : Larder[K, V]) -> Bool {
  self.table.is_empty()
}

///|
/// Keys in least- to most-recently-used order, including any that have
/// expired but haven't been purged yet.
pub fn[K, V] Larder::keys(self : Larder[K, V]) -> Iter[K] {
  self.table.keys()
}

///|
/// Values in least- to most-recently-used order, including any that have
/// expired but haven't been purged yet.
pub fn[K, V] Larder::values(self : Larder[K, V]) -> Iter[V] {
  self.table.values().map(fn(slot) { slot.value })
}

///|
/// A snapshot of every non-expired entry, in least- to most-recently-used
/// order. Unlike `keys`/`values`, this evaluates `now_ms` against every
/// entry up front rather than leaving expired ones in the result.
pub fn[K, V] Larder::to_array(
  self : Larder[K, V],
  now_ms~ : Int64,
) -> Array[(K, V)] {
  let out = []
  for key, slot in self.table {
    if !slot.is_expired(now_ms) {
      out.push((key, slot.value))
    }
  }
  out
}

///|
/// Inserts or updates `key`, moving it to the most-recently-used position.
///
/// `ttl_ms`, when given, overrides the cache's `default_ttl_ms` for this
/// entry only. If inserting pushes total weight over `capacity`,
/// least-recently-used entries (which may include the one just inserted,
/// if it doesn't fit even alone) are evicted until it fits or only one
/// entry remains.
pub fn[K : Hash + Eq, V] Larder::set(
  self : Larder[K, V],
  key : K,
  value : V,
  now_ms~ : Int64,
  ttl_ms? : Int64,
) -> Unit {
  let expire_at = self.resolve_expiry(now_ms, ttl_ms)
  let weight = (self.weigher)(key, value)
  match self.table.get(key) {
    Some(old_slot) => self.current_weight -= old_slot.weight
    None => ()
  }
  self.table.remove(key)
  self.table.set(key, { value, expire_at, weight, })
  self.current_weight += weight
  self.enforce_capacity()
}

///|
/// Refreshes `key`'s time-to-live without changing its value, moving it
/// to the most-recently-used position. Returns `false` if `key` is
/// absent or already expired - in which case an expired entry is
/// dropped, the same as `get` would - and leaves the cache unchanged.
///
/// `ttl_ms`, when given, overrides `default_ttl_ms` for this refresh,
/// the same as `set`'s `ttl_ms` argument does for a new value. This is
/// the usual way to implement sliding expiration (e.g. a session that
/// should stay alive as long as it's used) without having to read the
/// value back just to write it again.
pub fn[K : Hash + Eq, V] Larder::touch_ttl(
  self : Larder[K, V],
  key : K,
  now_ms~ : Int64,
  ttl_ms? : Int64,
) -> Bool {
  match self.table.get(key) {
    None => false
    Some(slot) =>
      if slot.is_expired(now_ms) {
        self.drop_expired(key, slot)
        false
      } else {
        let expire_at = self.resolve_expiry(now_ms, ttl_ms)
        self.touch(key, { value: slot.value, expire_at, weight: slot.weight, })
        true
      }
  }
}

///|
/// Returns the cached value for `key`, computing and storing it via
/// `compute` on a miss or expiry.
///
/// This is the usual way to memoize an expensive or repeated computation:
/// concurrent callers aside (`Larder` is not synchronized), a given key is
/// computed once per eviction/expiry cycle rather than on every call.
pub fn[K : Hash + Eq, V] Larder::get_or_insert_with(
  self : Larder[K, V],
  key : K,
  now_ms~ : Int64,
  ttl_ms? : Int64,
  compute : () -> V,
) -> V {
  match self.get(key, now_ms~) {
    Some(value) => value
    None => {
      let value = compute()
      self.set(key, value, now_ms~, ttl_ms?)
      value
    }
  }
}

///|
/// Like `get_or_insert_with`, but for a loader that can fail - a
/// database lookup or a parse, say. On a miss or expiry, `compute`'s
/// error propagates to the caller instead of being caught, and nothing
/// is stored: a failed load doesn't wedge a bad value into the cache
/// for the next caller to reuse.
pub fn[K : Hash + Eq, V, E : Error] Larder::try_get_or_insert_with(
  self : Larder[K, V],
  key : K,
  now_ms~ : Int64,
  ttl_ms? : Int64,
  compute : () -> V raise E,
) -> V raise E {
  match self.get(key, now_ms~) {
    Some(value) => value
    None => {
      let value = compute()
      self.set(key, value, now_ms~, ttl_ms?)
      value
    }
  }
}

///|
/// Removes `key` and returns its value, regardless of whether it had
/// already expired.
pub fn[K : Hash + Eq, V] Larder::remove(self : Larder[K, V], key : K) -> V? {
  match self.table.get(key) {
    None => None
    Some(slot) => {
      self.table.remove(key)
      self.current_weight -= slot.weight
      Some(slot.value)
    }
  }
}

///|
/// Removes every entry and resets the hit/miss/eviction/expiration
/// counters to zero.
pub fn[K, V] Larder::clear(self : Larder[K, V]) -> Unit {
  self.table.clear()
  self.current_weight = 0
  self.hit_count = 0
  self.miss_count = 0
  self.eviction_count = 0
  self.expiration_count = 0
}

///|
/// Removes every entry for which `predicate(key, value)` is `false`, and
/// returns how many were removed.
///
/// Useful for bulk invalidation by pattern - e.g. dropping every cached
/// entry under a prefix after the thing it was derived from changed -
/// where doing it key by key via `remove` would mean collecting matching
/// keys separately first.
pub fn[K : Hash + Eq, V] Larder::retain(
  self : Larder[K, V],
  predicate : (K, V) -> Bool,
) -> Int {
  let dropped = []
  for key, slot in self.table {
    if !predicate(key, slot.value) {
      dropped.push((key, slot.weight))
    }
  }
  for entry in dropped {
    self.table.remove(entry.0)
    self.current_weight -= entry.1
  }
  dropped.length()
}

///|
/// Removes every currently-expired entry and returns how many were
/// removed.
///
/// Expiry is otherwise lazy (checked on `get`/`contains`), so a cache that
/// is mostly written to and rarely read can accumulate expired entries
/// that still count against `capacity`; call this periodically if that
/// matters for your workload.
pub fn[K : Hash + Eq, V] Larder::purge_expired(
  self : Larder[K, V],
  now_ms~ : Int64,
) -> Int {
  let expired = []
  for key, slot in self.table {
    if slot.is_expired(now_ms) {
      expired.push((key, slot.weight))
    }
  }
  for entry in expired {
    self.table.remove(entry.0)
    self.current_weight -= entry.1
    self.expiration_count += 1
  }
  expired.length()
}

///|
/// The number of entries currently stored, including any that have
/// expired but have not yet been purged or looked up.
pub fn[K, V] Larder::size(self : Larder[K, V]) -> Int {
  self.table.length()
}

///|
/// The maximum weight this cache holds before evicting - an entry count,
/// unless `new` was given a `weigher`.
pub fn[K, V] Larder::capacity(self : Larder[K, V]) -> Int {
  self.capacity
}

///|
/// The current total weight of every stored entry (expired or not) - an
/// entry count, unless `new` was given a `weigher`. Always `<= capacity`,
/// except immediately after construction with a single entry whose own
/// weight already exceeds it.
pub fn[K, V] Larder::weight(self : Larder[K, V]) -> Int {
  self.current_weight
}

///|
/// Changes the cache's weight budget (see `new`'s `weigher` parameter).
///
/// Growing takes effect immediately with no other side effect. Shrinking
/// below the current weight evicts the least-recently-used entries right
/// away, the same as `set` would have, rather than waiting for the next
/// insert to notice the cache is over budget.
pub fn[K : Hash + Eq, V] Larder::resize(
  self : Larder[K, V],
  new_capacity : Int,
) -> Unit {
  guard new_capacity > 0 else {
    abort("Larder::resize: capacity must be positive, got \{new_capacity}")
  }
  self.capacity = new_capacity
  self.enforce_capacity()
}

///|
/// A snapshot of this cache's hit/miss/eviction/expiration counters.
pub fn[K, V] Larder::stats(self : Larder[K, V]) -> Stats {
  {
    hits: self.hit_count,
    misses: self.miss_count,
    evictions: self.eviction_count,
    expirations: self.expiration_count,
  }
}
