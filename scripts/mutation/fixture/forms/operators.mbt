// The site finder's fixture for operator set v1
// (scripts/mutation/test_mutation.py): each form of each operator, and the
// alternatives it makes in the full set, of which the pinned set takes the
// one the rule chooses (two for INT in a comparison or an index). The
// runner does not run this package, and it has no tests.

///|
/// A record with a field to assign.
pub(all) struct Point {
  mut x : Int32
}

///|
/// BODY: the default value of each return type.
pub fn body_unit(p : Point) -> Unit {
  p.x = 1
  p.x = 2
}

///|
pub fn body_int64(n : Int64) -> Int64 {
  n
}

///|
pub fn body_string(s : String) -> String {
  s
}

///|
pub fn body_option(n : Int32) -> Int32? {
  Some(n)
}

///|
pub fn body_array(n : Int32) -> Array[Int32] {
  [n]
}

///|
pub fn body_tuple(n : Int32) -> (Int32, Bool, Char) {
  (n, n > 0, 'a')
}

///|
pub fn body_result(s : String) -> Result[String, Int32] {
  Ok(s)
}

///|
/// No default: a type parameter, a type of the program's own, and a tuple
/// that holds one.
pub fn[T] body_generic(x : T) -> T {
  x
}

///|
pub fn body_own(x : Int32) -> Point {
  { x, }
}

///|
pub fn body_own_tuple(x : Int32) -> (Int32, Point) {
  (x, { x, })
}

///|
/// No site: the body already is the default value, or is empty.
pub fn body_already() -> Bool {
  false
}

///|
pub fn body_empty() -> Unit {

}

///|
/// FFI: the body is foreign, JavaScript, since ADR 0001 forbids C here.
pub extern "js" fn body_foreign(fd : Int32) -> Int32 = "(fd) => fd"

///|
/// The methods of core's traits, whose return types are not written.
pub impl Eq for Point with fn equal(self, other) {
  self.x == other.x
}

///|
/// IFC: each kind of condition. The pinned set takes false for an if, an
/// else if, a loop and a match arm's guard, and true for a guard
/// statement.
pub fn conditions(p : Point, o : Int32?) -> Int32 {
  if p.x > 0 {
    return 1
  } else if p.x < -5 {
    return 2
  }
  while p.x > 3 {
    p.x = p.x - 1
  }
  for i = 0; i < p.x; i = i + 1 {
    p.x = p.x + i
  }
  guard p.x != 7 else { return 3 }
  guard o is Some(_) else { return 4 }
  if o is Some(v) {
    return v
  }
  while true {
    break
  }
  match p.x {
    n if n > 9 => n
    _ => 0
  }
}

///|
/// LCR, and the skipped && whose operand binds a name.
pub fn logic(a : Bool, b : Bool, o : Int32?) -> Bool {
  if o is Some(v) && v > 0 {
    return a
  }
  (a && b) || o is None
}

///|
/// AOR: +, -, * and /, their compound assignments, and + on strings,
/// skipped.
pub fn arithmetic(p : Point, xs : Array[Int32], s : String) -> String {
  let mut n = p.x + 1 - 2 * 3 / 4 % 5
  n += 1
  n -= 2
  n *= 3
  n /= 4
  p.x += 5
  xs[0] *= 6
  "<" + s + "\{n}>"
}

///|
/// INT: in a comparison or an index, directly or through arithmetic, the
/// pinned set takes n+1 and n-1; elsewhere it takes n+1, or n-1 where n+1
/// does not fit the literal's type.
pub fn integers(xs : Array[Int32], n : Int32) -> Unit {
  ignore(n < 10)
  ignore(n - 1 >= 0)
  ignore(xs[2])
  ignore(xs[1:n])
  xs[n + 3] += 4
  ignore(xs.get(5))
  ignore(2147483647)
  ignore(0U)
  ignore(-1)
  ignore(0xFFL)
  ignore(1)
  match n {
    6 => ()
    _ => ()
  }
}

///|
/// DEL: the statements it deletes.
pub fn statements(p : Point, xs : Array[Int32]) -> Unit {
  let mut n = 0
  n = 1
  n += 2
  p.x = 3
  xs[0] = n
  xs[1] -= 5
  xs.push(6)
  ignore(n)
  n |> ignore
  if n > 0 {
    xs.clear()
  }
  let m = if n > 1 { xs.length() } else { 7 }
  for x in xs {
    ignore(x)
  }
  xs.push(m)
}

///|
/// DEL: the value of a block is not deleted, nor the only statement of a
/// function's body.
pub fn values(xs : Array[Int32]) -> Int32 {
  xs.push(8)
  xs.length()
}

///|
pub fn only(xs : Array[Int32]) -> Unit {
  xs.clear()
}

///|
/// Two sites that make the same mutant: one is kept.
pub fn yes() -> Bool {
  true
}

///|
pub fn one() -> Int32 {
  1
}
