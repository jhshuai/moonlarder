///|
test "a fresh sketch estimates zero for any key" {
  let s : @moonlarder.FrequencySketch[String] = @moonlarder.FrequencySketch::new(
    capacity=10,
  )
  assert_eq(s.estimate("never-seen"), 0)
}

///|
test "incrementing a key raises its own estimate" {
  let s : @moonlarder.FrequencySketch[String] = @moonlarder.FrequencySketch::new(
    capacity=10,
  )
  assert_eq(s.estimate("a"), 0)
  s.increment("a")
  assert_eq(s.estimate("a"), 1)
  s.increment("a")
  s.increment("a")
  assert_eq(s.estimate("a"), 3)
}

///|
test "incrementing one key does not raise a different key's estimate" {
  let s : @moonlarder.FrequencySketch[String] = @moonlarder.FrequencySketch::new(
    capacity=10,
  )
  for _i = 0; _i < 5; _i = _i + 1 {
    s.increment("a")
  }
  assert_eq(s.estimate("b"), 0)
}

///|
test "counters saturate and never exceed the cap even with many increments" {
  let s : @moonlarder.FrequencySketch[String] = @moonlarder.FrequencySketch::new(
    capacity=10,
  )
  for _i = 0; _i < 50; _i = _i + 1 {
    s.increment("a")
  }
  assert_eq(s.estimate("a"), 15)
}

///|
test "periodic aging keeps a heavily-incremented key's estimate from staying pinned at the cap forever" {
  let s : @moonlarder.FrequencySketch[String] = @moonlarder.FrequencySketch::new(
    capacity=10,
  )
  // Comfortably past both the per-counter cap (15) and the aging
  // threshold (~10x the table width) for a capacity-10 sketch, so at
  // least one halving must have happened by the end of this loop.
  for _i = 0; _i < 10_000; _i = _i + 1 {
    s.increment("a")
  }
  assert_true(s.estimate("a") < 15)
}

///|
test "clear resets every counter back to zero" {
  let s : @moonlarder.FrequencySketch[String] = @moonlarder.FrequencySketch::new(
    capacity=10,
  )
  for _i = 0; _i < 5; _i = _i + 1 {
    s.increment("a")
  }
  s.clear()
  assert_eq(s.estimate("a"), 0)
}

///|
test "panic FrequencySketch::new aborts on a non-positive capacity" {
  let _ : @moonlarder.FrequencySketch[String] = @moonlarder.FrequencySketch::new(
    capacity=0,
  )
}
