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
  /// Adaptively balances between recency and frequency (Megiddo and
  /// Modha, "ARC: A Self-Tuning, Low Overhead Replacement Cache", FAST
  /// 2003 - the algorithm ZFS's and PostgreSQL's buffer caches are
  /// built on), instead of committing to one or the other up front the
  /// way `Lru`/`Lfu` do. See `Larder::new`'s doc comment for what that
  /// buys you, this implementation's scope, and how it's adapted to
  /// fit `get`/`set` being separate calls. Not compatible with a
  /// custom `weigher` - `new` aborts if both are given.
  Arc
  /// The windowed TinyLFU architecture (Einziger, Friedman, and Manes,
  /// "TinyLFU: A Highly Efficient Cache Admission Policy", ACM TOS
  /// 2017, as structured in Caffeine's implementation): a small `Lru`
  /// "window" absorbs every new key first, giving it a chance to build
  /// up real request frequency before it has to prove itself: only
  /// when the window itself overflows does the evicted candidate
  /// contest admission into the larger main space against that space's
  /// own weakest entry, the same frequency comparison `admission_filter`
  /// runs directly against every newcomer. This is what
  /// `admission_filter` alone can't do - a key admission rejects on
  /// its very first appearance never gets a second chance to show it's
  /// actually popular. See `Larder::new`'s doc comment for the
  /// region-sizing rule and other scope limits. Not compatible with a
  /// custom `weigher`, and redundant with (so `new` aborts if combined
  /// with) `admission_filter`, since this policy already runs its own.
  WindowTinyLfu
} derive(Eq, Debug)

///|
pub extend EvictionPolicy with Eq::{not_equal, equal}

///|
pub extend EvictionPolicy with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Why an entry left the cache, passed to `new`'s `on_remove` listener.
pub(all) enum RemovalCause {
  /// Removed by `remove()`, or dropped by `retain()`'s predicate, or
  /// swept out individually by `clear()`.
  Explicit
  /// Overwritten by `set()` on a key that was already present. Carries
  /// the value being replaced, not the new one.
  Replaced
  /// Dropped for being past its time-to-live, whether discovered lazily
  /// (`get`/`contains`/`touch_ttl`) or by an explicit `purge_expired`.
  Expired
  /// Dropped by eviction under capacity/weight pressure, per `policy`.
  Evicted
} derive(Eq, Debug)

///|
pub extend RemovalCause with Eq::{not_equal, equal}

///|
pub extend RemovalCause with @moonbitlang/core/debug.Debug::{to_repr}

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
///
/// Pass `on_remove` to `new` to be notified whenever an entry leaves
/// the cache, with the reason - useful for cascading invalidation,
/// releasing a resource tied to the value (a file handle, say), or
/// just metrics.
pub struct Larder[K, V] {
  table : Map[K, Slot[V]]
  policy : EvictionPolicy
  mut capacity : Int
  default_ttl_ms : Int64?
  weigher : (K, V) -> Int
  on_remove : (K, V, RemovalCause) -> Unit
  mut current_weight : Int
  // LFU bookkeeping: freq_buckets[f] is the set of keys currently at
  // frequency f, and min_freq is the lowest frequency with a non-empty
  // bucket. Both stay empty/unused under the Lru policy.
  freq_buckets : Map[Int, Map[K, Unit]]
  mut min_freq : Int
  // ARC bookkeeping (Megiddo & Modha): arc_t1/arc_t2 are the "seen
  // once recently" and "seen more than once" lists that between them
  // hold every real entry; arc_b1/arc_b2 are ghost lists remembering
  // keys recently evicted from arc_t1/arc_t2 (no values - just enough
  // to recognize "this was here before"); arc_p is the current target
  // size for arc_t1. All stay empty/zero under the Lru and Lfu
  // policies.
  arc_t1 : Map[K, Unit]
  arc_t2 : Map[K, Unit]
  arc_b1 : Map[K, Unit]
  arc_b2 : Map[K, Unit]
  mut arc_p : Int
  // TinyLFU-style admission filter (see `new`'s `admission_filter?`
  // parameter): `Some` only when enabled, in which case `get` records
  // every lookup in it and a `set` of a brand-new key that would
  // require an eviction consults it first, rejecting the newcomer
  // outright rather than evicting a more historically popular entry to
  // make room for a less popular one. `None` (the default) costs
  // nothing beyond the one field.
  sketch : FrequencySketch[K]?
  mut rejected_count : Int
  // WindowTinyLfu bookkeeping: wtlfu_window is a small Lru region every
  // new key enters directly; wtlfu_probation and wtlfu_protected
  // together form the "main" space - an SLRU (segmented Lru) that a
  // window-evicted candidate only enters by winning the admission
  // contest. wtlfu_window_capacity and wtlfu_protected_capacity are
  // fixed fractions of `capacity`, recomputed on `resize`. All stay
  // empty/zero under every other policy.
  wtlfu_window : Map[K, Unit]
  wtlfu_probation : Map[K, Unit]
  wtlfu_protected : Map[K, Unit]
  mut wtlfu_window_capacity : Int
  mut wtlfu_protected_capacity : Int
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
    Arc => "arc"
    WindowTinyLfu => "wtinylfu"
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
/// LRU eviction, `remove`, or `clear`. A negative `default_ttl_ms` (or a
/// negative per-call `ttl_ms`) is honored rather than rejected: it
/// resolves to a deadline before `now_ms`, so the entry is already
/// expired the moment it's looked up - the same outcome `ttl_ms=0`
/// produces. A `ttl_ms` large enough that `now_ms + ttl_ms` would
/// overflow `Int64` saturates to "practically never expires" instead
/// of wrapping around to a deadline in the past.
///
/// `weigher`, when given, turns `capacity` into a weight budget rather
/// than a plain entry count: each entry contributes `weigher(key,
/// value)` instead of 1, clamped to at least 1 even if `weigher`
/// returns zero or a negative number - otherwise such an entry could
/// silently defeat capacity enforcement altogether. An entry whose own
/// weight exceeds `capacity` is still admitted alone (evicting
/// everything else) rather than being rejected, since `set` never
/// fails.
///
/// `policy` picks the eviction rule; it defaults to `Lru`.
///
/// `admission_filter`, when `true`, runs a TinyLFU-style admission
/// check (Einziger, Friedman, and Manes, ACM TOS 2017) in front of
/// eviction: inserting a brand-new key that would require evicting an
/// existing one first consults a `FrequencySketch` of every key
/// `get()` has looked up (hit or miss) so far, and rejects the
/// newcomer outright - leaving the cache unchanged - if it's estimated
/// *less* popular than the entry it would have displaced. This is what
/// protects a cache from a one-time bulk scan evicting a genuinely hot
/// working set, the same failure mode `policy=Arc` addresses by a
/// different mechanism. Only supported together with `policy=Lru` (or
/// no `policy` at all, since that defaults to `Lru`) and without a
/// custom `weigher` - `new` aborts if combined with `Lfu`/`Arc` or a
/// `weigher`. See `admission_rejections()` to observe how often it
/// fires.
///
/// `on_remove`, when given, is called synchronously every time an
/// entry leaves the cache for any reason (see `RemovalCause`), after
/// the cache's own state has already been updated to reflect the
/// removal - so a listener that calls back into the cache (`size()`,
/// `get()`, even inserting a replacement) sees consistent state, not a
/// half-finished removal.
///
/// `policy=WindowTinyLfu` splits `capacity` into a window (10%,
/// minimum 1) and a main space (the rest), itself split into a
/// protected segment (80% of main) and a probationary one (the
/// remainder) - Caffeine's own default ratios, simplified here to
/// fixed fractions rather than the hill-climbing adaptive resizing the
/// production system uses. Every new key lands in the window; only
/// when the window overflows does the evicted candidate contest
/// admission into probation against probation's own weakest entry (the
/// same comparison `admission_filter` runs directly against every
/// newcomer, but only after the candidate has had a chance to build up
/// real request frequency while sitting in the window). A probation
/// entry that gets a hit is promoted to protected; a protected entry
/// that overflows the protected segment demotes back to probation.
/// TTLs, `on_remove`, and everything else about `Larder` work the same
/// as under any other policy. Not compatible with a custom `weigher`
/// - `new` aborts if both are given - and redundant with
/// `admission_filter` (which only makes sense layered on `Lru`), so
/// `new` also aborts if both are given.
pub fn[K : Hash + Eq, V] Larder::new(
  capacity~ : Int,
  default_ttl_ms? : Int64,
  weigher? : (K, V) -> Int,
  policy? : EvictionPolicy,
  admission_filter? : Bool,
  on_remove? : (K, V, RemovalCause) -> Unit,
) -> Larder[K, V] {
  guard capacity > 0 else {
    abort("Larder::new: capacity must be positive, got \{capacity}")
  }
  let policy_weigher_conflict = match (policy, weigher) {
    (Some(Arc), Some(_)) => true
    (Some(WindowTinyLfu), Some(_)) => true
    _ => false
  }
  guard !policy_weigher_conflict else {
    abort("Larder::new: this policy doesn't support a custom weigher")
  }
  let filtered = match admission_filter {
    Some(enabled) => enabled
    None => false
  }
  let filter_needs_plain_lru = match policy {
    None => false
    Some(Lru) => false
    Some(_) => true
  }
  guard !(filtered && filter_needs_plain_lru) else {
    abort(
      "Larder::new: admission_filter is only supported with policy=Lru (WindowTinyLfu already runs its own)",
    )
  }
  let filter_with_weigher = match weigher {
    Some(_) => filtered
    None => false
  }
  guard !filter_with_weigher else {
    abort("Larder::new: admission_filter doesn't support a custom weigher")
  }
  let is_window_tiny_lfu = match policy {
    Some(WindowTinyLfu) => true
    _ => false
  }
  let (window_capacity, protected_capacity) = wtlfu_sizes(capacity)
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
    on_remove: match on_remove {
      Some(on_remove) => on_remove
      None => fn(_key, _value, _cause) { () }
    },
    current_weight: 0,
    freq_buckets: {},
    min_freq: 1,
    arc_t1: {},
    arc_t2: {},
    arc_b1: {},
    arc_b2: {},
    arc_p: 0,
    sketch: if filtered || is_window_tiny_lfu {
      Some(FrequencySketch::new(capacity~))
    } else {
      None
    },
    rejected_count: 0,
    wtlfu_window: {},
    wtlfu_probation: {},
    wtlfu_protected: {},
    wtlfu_window_capacity: window_capacity,
    wtlfu_protected_capacity: protected_capacity,
    hit_count: 0,
    miss_count: 0,
    eviction_count: 0,
    expiration_count: 0,
  }
}

///|
/// The window and protected-segment capacities `WindowTinyLfu` uses
/// for a cache of the given total `capacity` - see `Larder::new`'s doc
/// comment for the ratios. Shared by `new` and `resize` so both apply
/// the exact same rule.
fn wtlfu_sizes(capacity : Int) -> (Int, Int) {
  let window_capacity = (capacity / 10).max(1)
  let main_capacity = capacity - window_capacity
  let protected_capacity = main_capacity * 8 / 10
  (window_capacity, protected_capacity)
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
  admission_filter? : Bool,
  on_remove? : (K, V, RemovalCause) -> Unit,
  now_ms~ : Int64,
) -> Larder[K, V] {
  let cache = Larder::new(
    capacity~,
    default_ttl_ms?,
    weigher?,
    policy?,
    admission_filter?,
    on_remove?,
  )
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
const MAX_INT64 : Int64 = 9223372036854775807L

///|
const MIN_INT64 : Int64 = -9223372036854775808L

///|
/// `a + b`, clamped to `Int64`'s range instead of silently wrapping
/// around on overflow the way plain `+` does. Used for `now_ms + ttl`:
/// a `ttl_ms` large enough to overflow should behave like "practically
/// never expires" (saturate to `MAX_INT64`), not wrap around to a
/// small or negative deadline that makes the entry look *already*
/// expired - the opposite of what a long TTL asks for.
fn saturating_add_i64(a : Int64, b : Int64) -> Int64 {
  let sum = a + b
  if b >= 0L {
    if sum < a {
      MAX_INT64
    } else {
      sum
    }
  } else if sum > a {
    MIN_INT64
  } else {
    sum
  }
}

///|
/// A negative `ttl_ms` (whether passed to `set`/`touch_ttl` directly,
/// or via a negative `default_ttl_ms`) is honored rather than
/// rejected: it resolves to a deadline before `now_ms`, so the entry
/// is treated as already expired the moment it's looked up - the same
/// outcome `ttl_ms=0` produces, consistent with `set` never failing.
fn[K, V] Larder::resolve_expiry(
  self : Larder[K, V],
  now_ms : Int64,
  ttl_ms : Int64?,
) -> Int64? {
  match ttl_ms {
    Some(ttl) => Some(saturating_add_i64(now_ms, ttl))
    None =>
      match self.default_ttl_ms {
        Some(ttl) => Some(saturating_add_i64(now_ms, ttl))
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
/// Removes `key` from every internal structure it's tracked in
/// (`table`, `freq_buckets` under `Lfu`, `current_weight`) and fires
/// `on_remove` with `cause` - the one place every full removal funnels
/// through (an in-place value replacement in `set` is the one
/// exception, since the key isn't leaving), so `on_remove`'s "state is
/// already consistent" contract only has to be upheld here.
fn[K : Hash + Eq, V] Larder::discard(
  self : Larder[K, V],
  key : K,
  slot : Slot[V],
  cause : RemovalCause,
) -> Unit {
  self.table.remove(key)
  self.current_weight -= slot.weight
  match self.policy {
    Lru => ()
    Lfu => self.lfu_forget(key, slot.freq)
    Arc => {
      self.arc_t1.remove(key)
      self.arc_t2.remove(key)
    }
    WindowTinyLfu => {
      self.wtlfu_window.remove(key)
      self.wtlfu_probation.remove(key)
      self.wtlfu_protected.remove(key)
    }
  }
  (self.on_remove)(key, slot.value, cause)
}

///|
/// Evicts the least-recently-used entry, if any, without touching stats
/// other than `eviction_count`.
fn[K : Hash + Eq, V] Larder::evict_lru(self : Larder[K, V]) -> Unit {
  for key, slot in self.table {
    self.discard(key, slot, Evicted)
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
        (self.on_remove)(key, slot.value, Evicted)
      }
      None => ()
    }
    self.eviction_count += 1
    break
  }
}

///|
/// ARC's REPLACE(x, p) procedure: evicts one real entry, moving it to
/// the corresponding ghost list (`arc_b1`/`arc_b2`), choosing `arc_t1`
/// over `arc_t2` when `arc_t1` is over its target size `arc_p` - or, on
/// a tie with the target, when the request that triggered this
/// replacement was itself a ghost hit in `arc_b2` (`key_in_b2`). Only
/// called under the `Arc` policy.
fn[K : Hash + Eq, V] Larder::arc_replace(
  self : Larder[K, V],
  key_in_b2 : Bool,
) -> Unit {
  let t1_len = self.arc_t1.length()
  let from_t1 = t1_len >= 1 &&
    (t1_len > self.arc_p || (key_in_b2 && t1_len == self.arc_p))
  if from_t1 {
    for victim in self.arc_t1.keys() {
      self.arc_t1.remove(victim)
      self.arc_b1.set(victim, ())
      match self.table.get(victim) {
        Some(slot) => {
          self.discard(victim, slot, Evicted)
          self.eviction_count += 1
        }
        None => ()
      }
      break
    }
  } else {
    for victim in self.arc_t2.keys() {
      self.arc_t2.remove(victim)
      self.arc_b2.set(victim, ())
      match self.table.get(victim) {
        Some(slot) => {
          self.discard(victim, slot, Evicted)
          self.eviction_count += 1
        }
        None => ()
      }
      break
    }
  }
}

///|
/// Handles a `set()` on a key not currently in the cache, under the
/// `Arc` policy: adapts `arc_p` and runs `arc_replace` when `key` is a
/// ghost hit (cases I/II of Megiddo & Modha's algorithm), or makes room
/// per the cache's current fill state on a true miss (case III/IV),
/// then records `key` in `arc_t1` (true miss) or `arc_t2` (ghost hit) -
/// but does not touch `table` itself, which `set` handles right after
/// calling this. Only called under the `Arc` policy, before the new
/// entry is inserted.
fn[K : Hash + Eq, V] Larder::arc_insert_new_key(
  self : Larder[K, V],
  key : K,
) -> Unit {
  let in_b1 = self.arc_b1.contains(key)
  let in_b2 = self.arc_b2.contains(key)
  if in_b1 {
    let delta = (self.arc_b2.length() / self.arc_b1.length()).max(1)
    self.arc_p = (self.arc_p + delta).min(self.capacity)
    self.arc_replace(false)
    self.arc_b1.remove(key)
    self.arc_t2.set(key, ())
  } else if in_b2 {
    let delta = (self.arc_b1.length() / self.arc_b2.length()).max(1)
    self.arc_p = (self.arc_p - delta).max(0)
    self.arc_replace(true)
    self.arc_b2.remove(key)
    self.arc_t2.set(key, ())
  } else {
    let t1_len = self.arc_t1.length()
    let b1_len = self.arc_b1.length()
    let t2_len = self.arc_t2.length()
    let b2_len = self.arc_b2.length()
    if t1_len + b1_len == self.capacity {
      if t1_len < self.capacity {
        for oldest in self.arc_b1.keys() {
          self.arc_b1.remove(oldest)
          break
        }
        self.arc_replace(false)
      } else {
        // |T1| == capacity (so B1 is empty): T1 alone already fills the
        // whole cache, so its LRU entry is dropped outright rather than
        // becoming a ghost.
        for victim in self.arc_t1.keys() {
          self.arc_t1.remove(victim)
          match self.table.get(victim) {
            Some(slot) => {
              self.discard(victim, slot, Evicted)
              self.eviction_count += 1
            }
            None => ()
          }
          break
        }
      }
    } else if t1_len + t2_len + b1_len + b2_len >= self.capacity {
      if t1_len + t2_len + b1_len + b2_len >= 2 * self.capacity {
        for oldest in self.arc_b2.keys() {
          self.arc_b2.remove(oldest)
          break
        }
      }
      self.arc_replace(false)
    }
    self.arc_t1.set(key, ())
  }
}

///|
/// A generic fallback eviction for `WindowTinyLfu`, used by
/// `resize`'s shrink path rather than the admission-contest logic
/// `set` runs for a specific incoming candidate: evicts from the
/// window first (the least-proven region), then probation, then
/// protected - always leaving at least one entry in place, the same
/// guarantee `enforce_capacity`'s caller already provides.
fn[K : Hash + Eq, V] Larder::wtlfu_evict_fallback(self : Larder[K, V]) -> Unit {
  let region = if !self.wtlfu_window.is_empty() {
    self.wtlfu_window
  } else if !self.wtlfu_probation.is_empty() {
    self.wtlfu_probation
  } else {
    self.wtlfu_protected
  }
  for key in region.keys() {
    match self.table.get(key) {
      Some(slot) => {
        self.discard(key, slot, Evicted)
        self.eviction_count += 1
      }
      None => ()
    }
    break
  }
}

///|
/// Evicts one entry per `policy`, if any.
fn[K : Hash + Eq, V] Larder::evict_one(self : Larder[K, V]) -> Unit {
  match self.policy {
    Lru => self.evict_lru()
    Lfu => self.evict_lfu()
    Arc => self.arc_replace(false)
    WindowTinyLfu => self.wtlfu_evict_fallback()
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
  self.discard(key, slot, Expired)
  self.expiration_count += 1
}

///|
/// Records a hit on `key` for `WindowTinyLfu`'s own bookkeeping: moves
/// it to the most-recently-used position within whichever of
/// window/probation/protected it's currently in, promoting
/// probation -> protected on the way (demoting protected's own
/// least-recently-used entry back to probation if that promotion pushed
/// protected over its budget - a pure move between the two main
/// segments, not a removal, so it never touches `on_remove`).
fn[K : Hash + Eq, V] Larder::wtlfu_promote(
  self : Larder[K, V],
  key : K,
) -> Unit {
  if self.wtlfu_window.contains(key) {
    self.wtlfu_window.remove(key)
    self.wtlfu_window.set(key, ())
  } else if self.wtlfu_probation.contains(key) {
    self.wtlfu_probation.remove(key)
    self.wtlfu_protected.set(key, ())
    if self.wtlfu_protected.length() > self.wtlfu_protected_capacity {
      for oldest in self.wtlfu_protected.keys() {
        self.wtlfu_protected.remove(oldest)
        self.wtlfu_probation.set(oldest, ())
        break
      }
    }
  } else {
    self.wtlfu_protected.remove(key)
    self.wtlfu_protected.set(key, ())
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
    Arc => {
      if self.arc_t1.contains(key) {
        self.arc_t1.remove(key)
        self.arc_t2.set(key, ())
      } else {
        self.arc_t2.remove(key)
        self.arc_t2.set(key, ())
      }
      slot
    }
    WindowTinyLfu => {
      self.wtlfu_promote(key)
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
///
/// When `new` was given `admission_filter=true`, every call here - hit
/// or miss alike - also records `key` in the admission filter's
/// frequency sketch, since a key's *request* history (not just its
/// time as a cache member) is what the filter judges a future
/// newcomer's admission against.
pub fn[K : Hash + Eq, V] Larder::get(
  self : Larder[K, V],
  key : K,
  now_ms~ : Int64,
) -> V? {
  match self.sketch {
    Some(sketch) => sketch.increment(key)
    None => ()
  }
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
/// Looks up every key in `keys`, in order, returning only the hits as
/// `(key, value)` pairs - equivalent to calling `get` on each one and
/// collecting whichever returned `Some`, right down to updating
/// recency and hit/miss counters the same number of times (a key
/// repeated in `keys` is looked up, and counted, that many times over,
/// not deduplicated first).
///
/// The usual reason to reach for this instead of a loop of `get` calls
/// is a batch lookup by a list of IDs - filling in a page of search
/// results from the cache, say - where the loop itself is boilerplate
/// every call site would otherwise repeat.
pub fn[K : Hash + Eq, V] Larder::get_many(
  self : Larder[K, V],
  keys : Array[K],
  now_ms~ : Int64,
) -> Array[(K, V)] {
  let hits = []
  for key in keys {
    match self.get(key, now_ms~) {
      Some(value) => hits.push((key, value))
      None => ()
    }
  }
  hits
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
/// insertion order under `Lfu`/`Arc` (neither's own bookkeeping tracks a
/// total order over entries the way LRU's position in `Map` already
/// does for free). Includes entries that have expired but haven't been
/// purged yet, either way.
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
/// `{"capacity": .., "policy": "lru"|"lfu"|"arc", "entries": [{"key": ..,
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
    Arc => "arc"
    WindowTinyLfu => "wtinylfu"
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
/// Always uses the default (count-based) weigher, no default TTL, no
/// removal listener, and no admission filter: a weigher and a listener
/// are both functions, so there is nothing in JSON to deserialize them
/// from, and remaining TTL is deliberately not round-tripped at all -
/// a reloaded entry never expires on its own, rather than guessing
/// what "remaining" should mean relative to a `now_ms` that belongs to
/// a different call entirely. Use `to_array`/`from_array` directly,
/// supplying your own `weigher`/`default_ttl_ms`/`on_remove`/
/// `admission_filter`, if you need any of them.
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
    String("arc") => Arc
    String("wtinylfu") => WindowTinyLfu
    _ =>
      raise JsonDecodeError(
        (
          path.add_key("policy"),
          "Larder::from_json: expected \"lru\", \"lfu\", \"arc\", or \"wtinylfu\"",
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
///
/// Overwriting an already-present key fires `on_remove` with
/// `Replaced` and the value being discarded - the key itself isn't
/// leaving the cache, but that old value is, and a listener tracking a
/// resource tied to it (a file handle, say) needs to know.
///
/// When `new` was given `admission_filter=true` and inserting `key`
/// (not already present, weighing `weight`) would require evicting an
/// existing entry to make room, this is the TinyLFU admission check
/// itself: reject `key` outright, leaving the cache untouched, unless
/// it's estimated at least as popular as the entry `Lru` would have
/// evicted (ties favor the newcomer, so a cold sketch - every key
/// still at estimate 0 - doesn't degenerate into rejecting everything
/// forever). `Larder::new`'s guard against combining `admission_filter`
/// with anything but `Lru` is what lets this assume the eviction
/// victim is always simply `table`'s first entry.
///
/// Only ever applies under `Lru` (the one policy `admission_filter`
/// composes with) even though `self.sketch` is also populated under
/// `WindowTinyLfu` - that policy runs its own, differently-shaped
/// admission contest (`wtlfu_admit_or_reject`) entirely within
/// `wtlfu_insert_new_key`, and must not additionally be gated here.
fn[K : Hash, V] Larder::rejects_admission(
  self : Larder[K, V],
  key : K,
  weight : Int,
) -> Bool {
  match self.policy {
    Lru =>
      match self.sketch {
        None => false
        Some(sketch) =>
          if self.current_weight + weight <= self.capacity ||
            self.table.is_empty() {
            false
          } else {
            let mut victim_freq = 0
            for victim_key, _victim_slot in self.table {
              victim_freq = sketch.estimate(victim_key)
              break
            }
            sketch.estimate(key) < victim_freq
          }
      }
    _ => false
  }
}

///|
/// If `key` is currently a live entry, evicts it (`discard` plus the
/// `eviction_count` bump `evict_lru`/`evict_lfu`/`arc_replace` all do
/// the same way) - a no-op if it isn't, which lets callers pass a key
/// that may already be gone without checking first. Only meaningful
/// under `WindowTinyLfu`, whose admission contest can end with either
/// side (the candidate or the incumbent victim) being the one to leave.
fn[K : Hash + Eq, V] Larder::wtlfu_discard_if_present(
  self : Larder[K, V],
  key : K,
) -> Unit {
  match self.table.get(key) {
    Some(slot) => {
      self.discard(key, slot, Evicted)
      self.eviction_count += 1
    }
    None => ()
  }
}

///|
/// The TinyLFU admission contest itself, run on `candidate` - a key
/// just evicted from the window - against probation's own
/// least-recently-used entry, if main (probation + protected) has no
/// spare room for `candidate` outright. Ties favor `candidate`, the
/// same rule `rejects_admission` uses, for the same reason: a sketch
/// that has never seen either key shouldn't refuse every admission
/// forever.
fn[K : Hash + Eq, V] Larder::wtlfu_admit_or_reject(
  self : Larder[K, V],
  candidate : K,
) -> Unit {
  let main_capacity = self.capacity - self.wtlfu_window_capacity
  let main_len = self.wtlfu_probation.length() + self.wtlfu_protected.length()
  if main_len < main_capacity {
    self.wtlfu_probation.set(candidate, ())
  } else if self.wtlfu_probation.is_empty() {
    // main_capacity is 0 (a tiny total capacity) - there's never room,
    // so the candidate is simply evicted rather than contested.
    self.wtlfu_discard_if_present(candidate)
  } else {
    for victim in self.wtlfu_probation.keys() {
      let candidate_wins = match self.sketch {
        None => true
        Some(sketch) => sketch.estimate(candidate) >= sketch.estimate(victim)
      }
      if candidate_wins {
        self.wtlfu_probation.remove(victim)
        self.wtlfu_discard_if_present(victim)
        self.wtlfu_probation.set(candidate, ())
      } else {
        self.wtlfu_discard_if_present(candidate)
      }
      break
    }
  }
}

///|
/// Handles a `set()` on a key not currently in the cache, under
/// `WindowTinyLfu`: always admits `key` into the window first, then -
/// only if that pushed the window over its own budget - evicts the
/// window's least-recently-used entry and runs it through the
/// admission contest (`wtlfu_admit_or_reject`) for a place in main.
/// Does not touch `table` itself, which `set` handles right after
/// calling this, the same division of labor `arc_insert_new_key` uses.
fn[K : Hash + Eq, V] Larder::wtlfu_insert_new_key(
  self : Larder[K, V],
  key : K,
) -> Unit {
  self.wtlfu_window.set(key, ())
  if self.wtlfu_window.length() > self.wtlfu_window_capacity {
    for candidate in self.wtlfu_window.keys() {
      self.wtlfu_window.remove(candidate)
      self.wtlfu_admit_or_reject(candidate)
      break
    }
  }
}

///|
pub fn[K : Hash + Eq, V] Larder::set(
  self : Larder[K, V],
  key : K,
  value : V,
  now_ms~ : Int64,
  ttl_ms? : Int64,
) -> Unit {
  let expire_at = self.resolve_expiry(now_ms, ttl_ms)
  // Clamped to at least 1: a weigher that returns 0 or negative for
  // some entry would otherwise let that entry grow current_weight by
  // nothing (or shrink it), silently defeating enforce_capacity's
  // `current_weight > capacity` check and letting the cache grow
  // without bound. Every entry counts for at least 1 regardless of
  // what a buggy or adversarial weigher returns.
  let weight = (self.weigher)(key, value).max(1)
  match self.table.get(key) {
    None if self.rejects_admission(key, weight) => {
      self.rejected_count += 1
      return
    }
    Some(old_slot) => {
      self.current_weight -= old_slot.weight
      let freq = match self.policy {
        Lru => old_slot.freq
        Arc => old_slot.freq
        WindowTinyLfu => old_slot.freq
        Lfu => self.lfu_bump(key, old_slot.freq)
      }
      let new_slot = { value, expire_at, weight, freq, }
      match self.policy {
        Lru => self.touch(key, new_slot)
        Lfu => self.table.set(key, new_slot)
        Arc => {
          if self.arc_t1.contains(key) {
            self.arc_t1.remove(key)
            self.arc_t2.set(key, ())
          } else {
            self.arc_t2.remove(key)
            self.arc_t2.set(key, ())
          }
          self.table.set(key, new_slot)
        }
        WindowTinyLfu => {
          self.wtlfu_promote(key)
          self.table.set(key, new_slot)
        }
      }
      (self.on_remove)(key, old_slot.value, Replaced)
    }
    None => {
      let new_slot : Slot[V] = { value, expire_at, weight, freq: 1, }
      match self.policy {
        Lru => self.table.set(key, new_slot)
        Lfu => {
          self.table.set(key, new_slot)
          self.lfu_register(key)
        }
        Arc => {
          self.arc_insert_new_key(key)
          self.table.set(key, new_slot)
        }
        WindowTinyLfu => {
          self.wtlfu_insert_new_key(key)
          self.table.set(key, new_slot)
        }
      }
    }
  }
  self.current_weight += weight
  self.enforce_capacity()
}

///|
/// Inserts or updates every entry in `entries`, in order, under the
/// same `ttl_ms` - equivalent to calling `set` on each pair in turn,
/// right down to possibly evicting an earlier pair in `entries` itself
/// to make room for a later one.
///
/// The usual reason to reach for this instead of a loop of `set` calls
/// is a bulk warm-up or refresh - reloading a page of rows just read
/// from a database, say - where every entry shares one `ttl_ms` and the
/// loop itself is boilerplate every call site would otherwise repeat.
pub fn[K : Hash + Eq, V] Larder::set_many(
  self : Larder[K, V],
  entries : Array[(K, V)],
  now_ms~ : Int64,
  ttl_ms? : Int64,
) -> Unit {
  for entry in entries {
    self.set(entry.0, entry.1, now_ms~, ttl_ms?)
  }
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
          Arc => slot.freq
          WindowTinyLfu => slot.freq
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
          WindowTinyLfu => {
            self.wtlfu_promote(key)
            self.table.set(key, new_slot)
          }
          Arc => {
            if self.arc_t1.contains(key) {
              self.arc_t1.remove(key)
              self.arc_t2.set(key, ())
            } else {
              self.arc_t2.remove(key)
              self.arc_t2.set(key, ())
            }
            self.table.set(key, new_slot)
          }
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
      let value = slot.value
      self.discard(key, slot, Explicit)
      Some(value)
    }
  }
}

///|
/// Removes every entry (firing `on_remove` with `Explicit` for each,
/// once the cache is already empty - the same "state is consistent
/// first" order `new`'s `on_remove` doc comment promises for every
/// other removal path) and resets the hit/miss/eviction/expiration
/// counters to zero.
pub fn[K, V] Larder::clear(self : Larder[K, V]) -> Unit {
  let removed = []
  for key, slot in self.table {
    removed.push((key, slot.value))
  }
  self.table.clear()
  self.current_weight = 0
  self.freq_buckets.clear()
  self.min_freq = 1
  self.arc_t1.clear()
  self.arc_t2.clear()
  self.arc_b1.clear()
  self.arc_b2.clear()
  self.arc_p = 0
  self.wtlfu_window.clear()
  self.wtlfu_probation.clear()
  self.wtlfu_protected.clear()
  match self.sketch {
    Some(sketch) => sketch.clear()
    None => ()
  }
  self.rejected_count = 0
  self.hit_count = 0
  self.miss_count = 0
  self.eviction_count = 0
  self.expiration_count = 0
  for entry in removed {
    (self.on_remove)(entry.0, entry.1, Explicit)
  }
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
      dropped.push((key, slot))
    }
  }
  for entry in dropped {
    self.discard(entry.0, entry.1, Explicit)
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
      expired.push((key, slot))
    }
  }
  for entry in expired {
    self.drop_expired(entry.0, entry.1)
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
/// How many `set()` calls on a new key have been turned away by the
/// admission filter (see `new`'s `admission_filter?` parameter) since
/// this cache was created or last `clear()`ed. Always `0` when the
/// filter isn't enabled.
pub fn[K, V] Larder::admission_rejections(self : Larder[K, V]) -> Int {
  self.rejected_count
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
  self.arc_p = self.arc_p.min(new_capacity)
  if self.policy == WindowTinyLfu {
    let (window_capacity, protected_capacity) = wtlfu_sizes(new_capacity)
    self.wtlfu_window_capacity = window_capacity
    self.wtlfu_protected_capacity = protected_capacity
  }
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
