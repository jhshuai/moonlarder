///|
/// Which entry `Larder` evicts first once it's over capacity.
pub(all) enum EvictionPolicy {
  /// Evict the least-recently-used entry - the default.
  Lru
  /// Evict the least-frequently-used entry, breaking ties among entries
  /// at the same frequency in favor of whichever was used least
  /// recently. A brand-new entry starts at the lowest possible
  /// frequency, so - correctly, per LFU's own definition, not as a bug -
  /// it can be evicted almost immediately if the cache is already full
  /// of entries accessed more than once.
  Lfu
} derive(Eq, Debug)

///|
pub extend EvictionPolicy with Eq::{not_equal, equal}

///|
pub extend EvictionPolicy with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A bounded, expiring in-memory cache.
///
/// Entries beyond `capacity` are evicted according to `policy` once
/// there's no room for a new one, and an entry older than its
/// time-to-live is treated as absent the next time it's looked up. The
/// clock is supplied by the caller on every call that needs one
/// (`now_ms`) instead of being read internally, so behavior stays
/// deterministic and testable regardless of target or wall-clock source.
///
/// By default `capacity` counts entries (every entry weighs 1). Pass
/// `weigher` to `new` to have it count something else instead - total
/// byte size, say, for a cache of blobs where a handful of large ones
/// shouldn't crowd out many small ones the way plain entry-counting
/// would let them.
pub struct Larder[K, V] {
  table : Map[K, Slot[V]]
  policy : EvictionPolicy
  mut capacity : Int
  default_ttl_ms : Int64?
  weigher : (K, V) -> Int
  mut current_weight : Int
  // LFU bookkeeping: freq_buckets[f] is the set of keys currently at
  // frequency f, and min_freq is the lowest frequency with a non-empty
  // bucket. Both stay empty/unused under the Lru policy.
  freq_buckets : Map[Int, Map[K, Unit]]
  mut min_freq : Int
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
  freq : Int // access count; only meaningful under the Lfu policy
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
/// Prints as `Larder(size=.., capacity=.., weight=.., policy=..)` - a
/// structural summary, not a dump of every key and value. Larger caches
/// make a full dump impractical to read, and a cache's entries may not
/// even be worth printing (nothing here requires `K`/`V` to implement
/// `Show`).
pub impl[K, V] Show for Larder[K, V] with fn output(self, logger) {
  let policy = match self.policy {
    Lru => "lru"
    Lfu => "lfu"
  }
  logger.write_string(
    "Larder(size=\{self.table.length()}, capacity=\{self.capacity}, weight=\{self.current_weight}, policy=\{policy})",
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
///
/// `policy` picks the eviction rule; it defaults to `Lru`.
pub fn[K : Hash + Eq, V] Larder::new(
  capacity~ : Int,
  default_ttl_ms? : Int64,
  weigher? : (K, V) -> Int,
  policy? : EvictionPolicy,
) -> Larder[K, V] {
  guard capacity > 0 else {
    abort("Larder::new: capacity must be positive, got \{capacity}")
  }
  {
    table: {},
    policy: match policy {
      Some(policy) => policy
      None => Lru
    },
    capacity,
    default_ttl_ms,
    weigher: match weigher {
      Some(weigher) => weigher
      None => fn(_key, _value) { 1 }
    },
    current_weight: 0,
    freq_buckets: {},
    min_freq: 1,
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
  policy? : EvictionPolicy,
  now_ms~ : Int64,
) -> Larder[K, V] {
  let cache = Larder::new(capacity~, default_ttl_ms?, weigher?, policy?)
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
/// recency is tracked by removing and re-inserting the entry. Only
/// meaningful under the `Lru` policy.
fn[K : Hash + Eq, V] Larder::touch(
  self : Larder[K, V],
  key : K,
  slot : Slot[V],
) -> Unit {
  self.table.remove(key)
  self.table.set(key, slot)
}

///|
/// Registers a brand-new key at frequency 1 in `freq_buckets`, and resets
/// `min_freq` to 1 - always correct immediately afterward, since bucket 1
/// now certainly has at least this one key in it. Only called under the
/// `Lfu` policy.
fn[K : Hash + Eq, V] Larder::lfu_register(self : Larder[K, V], key : K) -> Unit {
  let bucket = self.freq_buckets.get_or_init(1, fn() { {} })
  bucket.set(key, ())
  self.min_freq = 1
}

///|
/// Moves `key` from frequency `old_freq` to `old_freq + 1` in
/// `freq_buckets` and returns the new frequency. If emptying the old
/// bucket empties what was the minimum-frequency bucket, `min_freq`
/// advances by exactly one to match - the bucket key just vacated is the
/// only candidate that could newly be the minimum, since frequencies
/// only ever increase. Only called under the `Lfu` policy.
fn[K : Hash + Eq, V] Larder::lfu_bump(
  self : Larder[K, V],
  key : K,
  old_freq : Int,
) -> Int {
  let new_freq = old_freq + 1
  match self.freq_buckets.get(old_freq) {
    Some(bucket) => {
      bucket.remove(key)
      if bucket.is_empty() {
        self.freq_buckets.remove(old_freq)
        if old_freq == self.min_freq {
          self.min_freq = new_freq
        }
      }
    }
    None => ()
  }
  let new_bucket = self.freq_buckets.get_or_init(new_freq, fn() { {} })
  new_bucket.set(key, ())
  new_freq
}

///|
/// Removes `key` from `freq_buckets` when it leaves the cache for a
/// reason other than a frequency bump (an explicit `remove`, `retain`,
/// `clear`, `purge_expired`, or eviction itself). Deliberately does not
/// try to keep `min_freq` accurate here - `lfu_evict` corrects it lazily
/// instead, which is simpler to get right than chasing every removal
/// path and no less efficient (each stale step is only ever walked past
/// once before `min_freq` catches up or a fresh insert resets it to 1).
/// Only called under the `Lfu` policy.
fn[K : Hash + Eq, V] Larder::lfu_forget(
  self : Larder[K, V],
  key : K,
  freq : Int,
) -> Unit {
  match self.freq_buckets.get(freq) {
    Some(bucket) => {
      bucket.remove(key)
      if bucket.is_empty() {
        self.freq_buckets.remove(freq)
      }
    }
    None => ()
  }
}

///|
/// Evicts the least-recently-used entry, if any, without touching stats
/// other than `eviction_count`.
fn[K : Hash + Eq, V] Larder::evict_lru(self : Larder[K, V]) -> Unit {
  for key, slot in self.table {
    self.table.remove(key)
    self.current_weight -= slot.weight
    self.eviction_count += 1
    break
  }
}

///|
/// Evicts one entry at the current minimum frequency (ties broken by
/// insertion/least-recent order within that frequency's bucket), without
/// touching stats other than `eviction_count`.
fn[K : Hash + Eq, V] Larder::evict_lfu(self : Larder[K, V]) -> Unit {
  while !self.freq_buckets.contains(self.min_freq) {
    self.min_freq += 1
  }
  let bucket = self.freq_buckets.get(self.min_freq).unwrap()
  for key in bucket.keys() {
    bucket.remove(key)
    if bucket.is_empty() {
      self.freq_buckets.remove(self.min_freq)
    }
    match self.table.get(key) {
      Some(slot) => {
        self.table.remove(key)
        self.current_weight -= slot.weight
      }
      None => ()
    }
    self.eviction_count += 1
    break
  }
}

///|
/// Evicts one entry per `policy`, if any.
fn[K : Hash + Eq, V] Larder::evict_one(self : Larder[K, V]) -> Unit {
  match self.policy {
    Lru => self.evict_lru()
    Lfu => self.evict_lfu()
  }
}

///|
/// Evicts entries until `current_weight` is back within `capacity`,
/// always leaving at least one entry in place so a single entry heavier
/// than `capacity` doesn't evict itself.
fn[K : Hash + Eq, V] Larder::enforce_capacity(self : Larder[K, V]) -> Unit {
  while self.current_weight > self.capacity && self.table.length() > 1 {
    self.evict_one()
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
  match self.policy {
    Lru => ()
    Lfu => self.lfu_forget(key, slot.freq)
  }
}

///|
/// Records a live hit on an already-present, non-expired `key`: moves it
/// to the most-recently-used position under `Lru`, or bumps its access
/// frequency under `Lfu`. Returns the (possibly updated) slot now stored
/// for `key`.
fn[K : Hash + Eq, V] Larder::record_access(
  self : Larder[K, V],
  key : K,
  slot : Slot[V],
) -> Slot[V] {
  match self.policy {
    Lru => {
      self.touch(key, slot)
      slot
    }
    Lfu => {
      let freq = self.lfu_bump(key, slot.freq)
      let updated = {
        value: slot.value,
        expire_at: slot.expire_at,
        weight: slot.weight,
        freq,
      }
      self.table.set(key, updated)
      updated
    }
  }
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
        let updated = self.record_access(key, slot)
        self.hit_count += 1
        Some(updated.value)
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
/// Keys in least- to most-recently-used order under `Lru`, or plain
/// insertion order under `Lfu` (the frequency bookkeeping doesn't track
/// a total order over entries the way LRU's own position in `Map`
/// already does for free). Includes entries that have expired but
/// haven't been purged yet, either way.
pub fn[K, V] Larder::keys(self : Larder[K, V]) -> Iter[K] {
  self.table.keys()
}

///|
/// Same order as `keys`.
pub fn[K, V] Larder::values(self : Larder[K, V]) -> Iter[V] {
  self.table.values().map(fn(slot) { slot.value })
}

///|
/// Supports `for (key, value) in larder { .. }`. Same order and the same
/// inclusion of not-yet-purged expired entries as `keys`/`values`.
pub fn[K, V] Larder::iter(self : Larder[K, V]) -> Iter[(K, V)] {
  self.table.iter().map(fn(entry) { (entry.0, entry.1.value) })
}

///|
/// Supports `for key, value in larder { .. }` - the two-variable form of
/// the same iteration `iter` provides.
pub fn[K, V] Larder::iter2(self : Larder[K, V]) -> Iter2[K, V] {
  let inner = self.table.iter()
  Iter2::new(fn() {
    match inner.next() {
      Some((key, slot)) => Some((key, slot.value))
      None => None
    }
  })
}

///|
/// A snapshot of every non-expired entry, in the same order as `keys`.
/// Unlike `keys`/`values`, this evaluates `now_ms` against every entry
/// up front rather than leaving expired ones in the result.
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
/// `{"capacity": .., "policy": "lru"|"lfu", "entries": [{"key": ..,
/// "value": ..}, ..]}`. Includes every stored entry, expired or not -
/// the same contract as `keys`/`values`, since `ToJson`'s signature
/// takes no clock to compare deadlines against. Call `purge_expired`
/// first if that matters.
///
/// See `FromJson`'s doc comment for what does and doesn't round-trip.
pub impl[K : ToJson, V : ToJson] ToJson for Larder[K, V] with fn to_json(self) {
  let policy = match self.policy {
    Lru => "lru"
    Lfu => "lfu"
  }
  let entries = []
  for key, slot in self.table {
    entries.push(
      Json::object({
        "key": ToJson::to_json(key),
        "value": ToJson::to_json(slot.value),
      }),
    )
  }
  Json::object({
    "capacity": Json::number(self.capacity.to_double()),
    "policy": Json::string(policy),
    "entries": Json::array(entries),
  })
}

///|
/// Reconstructs a `Larder` from a snapshot written by `ToJson`, with
/// capacity and policy taken from the JSON and entries re-inserted in
/// the order they were written - the same eviction rules `from_array`
/// follows if they don't all fit.
///
/// Always uses the default (count-based) weigher and no default TTL:
/// a weigher is a function, so there is nothing in JSON to deserialize
/// it from, and remaining TTL is deliberately not round-tripped at all
/// - a reloaded entry never expires on its own, rather than guessing
/// what "remaining" should mean relative to a `now_ms` that belongs to
/// a different call entirely. Use `to_array`/`from_array` directly,
/// supplying your own `weigher`/`default_ttl_ms`, if you need either
/// preserved.
pub impl[K : Hash + Eq + FromJson, V : FromJson] FromJson for Larder[K, V] with fn from_json(
  json,
  path,
) {
  guard json is Object(fields) else {
    raise JsonDecodeError((path, "Larder::from_json: expected an object"))
  }
  guard fields.get("capacity") is Some(capacity_json) else {
    raise JsonDecodeError((path, "Larder::from_json: missing \"capacity\""))
  }
  guard fields.get("policy") is Some(policy_json) else {
    raise JsonDecodeError((path, "Larder::from_json: missing \"policy\""))
  }
  guard fields.get("entries") is Some(entries_json) else {
    raise JsonDecodeError((path, "Larder::from_json: missing \"entries\""))
  }
  let capacity : Int = @json.from_json(
    capacity_json,
    path=path.add_key("capacity"),
  )
  let policy = match policy_json {
    String("lru") => Lru
    String("lfu") => Lfu
    _ =>
      raise JsonDecodeError(
        (
          path.add_key("policy"),
          "Larder::from_json: expected \"lru\" or \"lfu\"",
        ),
      )
  }
  guard entries_json is Array(items) else {
    raise JsonDecodeError(
      (path.add_key("entries"), "Larder::from_json: expected an array"),
    )
  }
  let cache : Larder[K, V] = Larder::new(capacity~, policy~)
  for i, item in items {
    let item_path = path.add_key("entries").add_index(i)
    guard item is Object(entry_fields) else {
      raise JsonDecodeError(
        (item_path, "Larder::from_json: expected an object"),
      )
    }
    guard entry_fields.get("key") is Some(key_json) else {
      raise JsonDecodeError((item_path, "Larder::from_json: missing \"key\""))
    }
    guard entry_fields.get("value") is Some(value_json) else {
      raise JsonDecodeError((item_path, "Larder::from_json: missing \"value\""))
    }
    let key : K = @json.from_json(key_json, path=item_path.add_key("key"))
    let value : V = @json.from_json(value_json, path=item_path.add_key("value"))
    cache.set(key, value, now_ms=0L)
  }
  cache
}

///|
pub extend Larder with ToJson::{to_json}

///|
pub extend Larder with @moonbitlang/core/json.FromJson::{from_json}

///|
/// Inserts or updates `key`, moving it to the most-recently-used position
/// under `Lru`, or bumping its access frequency under `Lfu` (a new key
/// always starts at the lowest frequency either way).
///
/// `ttl_ms`, when given, overrides the cache's `default_ttl_ms` for this
/// entry only. If inserting pushes total weight over `capacity`,
/// entries are evicted per `policy` (which may include the one just
/// inserted, if it doesn't fit even alone) until it fits or only one
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
    Some(old_slot) => {
      self.current_weight -= old_slot.weight
      let freq = match self.policy {
        Lru => old_slot.freq
        Lfu => self.lfu_bump(key, old_slot.freq)
      }
      let new_slot = { value, expire_at, weight, freq, }
      match self.policy {
        Lru => self.touch(key, new_slot)
        Lfu => self.table.set(key, new_slot)
      }
    }
    None => {
      self.table.set(key, { value, expire_at, weight, freq: 1, })
      match self.policy {
        Lru => ()
        Lfu => self.lfu_register(key)
      }
    }
  }
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
        let freq = match self.policy {
          Lru => slot.freq
          Lfu => self.lfu_bump(key, slot.freq)
        }
        let new_slot = {
          value: slot.value,
          expire_at,
          weight: slot.weight,
          freq,
        }
        match self.policy {
          Lru => self.touch(key, new_slot)
          Lfu => self.table.set(key, new_slot)
        }
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
      match self.policy {
        Lru => ()
        Lfu => self.lfu_forget(key, slot.freq)
      }
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
  self.freq_buckets.clear()
  self.min_freq = 1
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
      dropped.push((key, slot.weight, slot.freq))
    }
  }
  for entry in dropped {
    self.table.remove(entry.0)
    self.current_weight -= entry.1
    match self.policy {
      Lru => ()
      Lfu => self.lfu_forget(entry.0, entry.2)
    }
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
      expired.push((key, slot.weight, slot.freq))
    }
  }
  for entry in expired {
    self.table.remove(entry.0)
    self.current_weight -= entry.1
    self.expiration_count += 1
    match self.policy {
      Lru => ()
      Lfu => self.lfu_forget(entry.0, entry.2)
    }
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
/// This cache's eviction policy, as given to `new`.
pub fn[K, V] Larder::policy(self : Larder[K, V]) -> EvictionPolicy {
  self.policy
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
