///|
/// `estimate(key)` must never fall below `key`'s true occurrence count,
/// the core Count-Min Sketch guarantee - checked here against an
/// independent, deliberately naive `Map[Int, Int]` of exact counts,
/// the same differential-testing approach `moonlarder_qc_test.mbt` uses
/// for the real `Larder` policies. Capped at the sketch's own counter
/// ceiling (15): once a count saturates, the guarantee is "never below
/// the cap", not "never below the (now unrepresentable) true count" -
/// see `FrequencySketch::increment`'s doc comment. `fold_key` (defined
/// in `moonlarder_qc_test.mbt`) keeps the key space small enough that
/// both saturation and hash collisions actually get exercised.
fn prop_frequency_sketch_never_underestimates(ops : Array[Int]) -> Bool {
  let sketch : @moonlarder.FrequencySketch[Int] = @moonlarder.FrequencySketch::new(
    capacity=50,
  )
  let exact : Map[Int, Int] = Map([])
  for raw in ops {
    let key = fold_key(raw)
    sketch.increment(key)
    let previous = match exact.get(key) {
      Some(count) => count
      None => 0
    }
    exact.set(key, previous + 1)
  }
  for entry in exact {
    let (key, true_count) = entry
    if sketch.estimate(key) < true_count.min(15) {
      return false
    }
  }
  true
}

///|
test "property: a frequency sketch never underestimates a key's true count, up to its own cap" {
  @quickcheck.quick_check_fn(prop_frequency_sketch_never_underestimates)
}
