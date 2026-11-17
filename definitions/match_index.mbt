// The match index of a Mock: its HTTP Stubs grouped by the method and the
// exact path a request needs for them to match, so that finding the Stub
// that answers a request does not try every Stub of the Mock. gRPC Stubs
// are not in it: HTTP requests never match them.
//
// The index never changes which Stub answers. A lookup tries every Stub
// the request could match, in matching order; it leaves out only Stubs
// whose exact method or exact path differs from the request's. Stubs that
// cannot be indexed, with neither an exact path nor a method, and CRUD
// Stubs, are given for every request, in their place in the order.

///|
/// The Stubs of a Mock, by their position in matching order, grouped by
/// their method and exact path conditions. Every list of positions is in
/// ascending order.
#derive(Debug, Eq)
priv struct MatchIndex {
  /// The Stubs with an exact path condition, by that path.
  by_path : Map[String, PathStubs]
  /// The Stubs with a method condition and no exact path condition, such
  /// as a path pattern, by method.
  by_method : Map[String, Array[Int32]]
  /// The Stubs with neither a method nor an exact path condition, and the
  /// CRUD Stubs: they are tried for every request.
  scanned : Array[Int32]
}

///|
/// The Stubs with one exact path condition.
#derive(Debug, Eq)
priv struct PathStubs {
  /// The Stubs that also have a method condition, by method.
  by_method : Map[String, Array[Int32]]
  /// The Stubs without a method condition.
  any_method : Array[Int32]
}

///|
/// Indexes `stubs`, given in matching order.
fn MatchIndex::new(stubs : ReadOnlyArray[Stub]) -> MatchIndex {
  let index : MatchIndex = {
    by_path: Map([]),
    by_method: Map([]),
    scanned: [],
  }
  for position, stub in stubs {
    match stub.serves {
      Ordinary(ordinary) =>
        match (ordinary.request.path, ordinary.request.meth) {
          (Some(Has(Exact(path))), meth) => {
            let stubs = match index.by_path.get(path) {
              Some(stubs) => stubs
              None => {
                let stubs = { by_method: Map([]), any_method: [], }
                index.by_path[path] = stubs
                stubs
              }
            }
            match meth {
              Some(meth) => add_position(stubs.by_method, meth, position)
              None => stubs.any_method.push(position)
            }
          }
          (_, Some(meth)) => add_position(index.by_method, meth, position)
          (_, None) => index.scanned.push(position)
        }
      // A CRUD Stub has no single method and no exact path: it is tried
      // for every request of its Mock, behind the cheap prefix test of its
      // path (`Crud::operation`).
      Crud(_) => index.scanned.push(position)
    }
  }
  index
}

///|
/// Appends `position` to the list of `key` in `lists`.
fn add_position(
  lists : Map[String, Array[Int32]],
  key : String,
  position : Int32,
) -> Unit {
  match lists.get(key) {
    Some(list) => list.push(position)
    None => lists[key] = [position]
  }
}

///|
/// No positions, for a list the match index does not have.
let no_positions : Array[Int32] = []

///|
/// The first Stub, in matching order, among the HTTP Stubs of this Mock that
/// a request with the method `meth` and the path `path` can match, for which
/// `accepts` holds, or `None`. `path` is percent-decoded and without the
/// query, as path conditions compare it.
///
/// The Stubs are found through the Mock's match index, built with the
/// snapshot, with a merge over the index's lists and no iterator or closure
/// per Stub, since every request looks for one. Every Stub the index leaves
/// out has an exact method or an exact path condition that the request does
/// not meet, so when `accepts` tells whether the request matches a Stub, the
/// result is the first Stub of `http_stubs` that it matches.
pub fn Mock::first_candidate(
  self : Mock,
  meth : String,
  path : String,
  accepts : (Stub) -> Bool,
) -> Stub? {
  let index = self.index
  // The Stubs with the request's exact path and method, those with its
  // exact path and no method, those with its method and no exact path, and
  // those scanned for every request. A Stub is in one list at most, so the
  // lists never share a position.
  let mut by_path_method = no_positions
  let mut by_path_any = no_positions
  if index.by_path.get(path) is Some(stubs) {
    if stubs.by_method.get(meth) is Some(list) {
      by_path_method = list
    }
    by_path_any = stubs.any_method
  }
  let by_method = match index.by_method.get(meth) {
    Some(list) => list
    None => no_positions
  }
  let scanned = index.scanned
  let mut a = 0
  let mut b = 0
  let mut c = 0
  let mut d = 0
  for ;; {
    // The lowest next position of the four lists.
    let mut position = @int.MAX_VALUE
    let mut list = -1
    if a < by_path_method.length() && by_path_method[a] < position {
      position = by_path_method[a]
      list = 0
    }
    if b < by_path_any.length() && by_path_any[b] < position {
      position = by_path_any[b]
      list = 1
    }
    if c < by_method.length() && by_method[c] < position {
      position = by_method[c]
      list = 2
    }
    if d < scanned.length() && scanned[d] < position {
      position = scanned[d]
      list = 3
    }
    match list {
      0 => a += 1
      1 => b += 1
      2 => c += 1
      3 => d += 1
      _ => return None
    }
    let stub = self.http_stubs[position]
    if accepts(stub) {
      return Some(stub)
    }
  }
}
