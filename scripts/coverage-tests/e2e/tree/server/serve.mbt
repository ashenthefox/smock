///|
/// A server that stands in for smock's, in the tests of
/// scripts/coverage-e2e.py: a body of each kind, some reached and some
/// not, which scripts/coverage-tests/e2e/README.md lists.
pub struct Server {
  mut hits : Int
}

///|
/// A server that has answered nothing.
pub fn Server::new() -> Server {
  { hits: 0 }
}

///|
/// Answers a request for a path: 400 for no path, 414 for a long one.
pub fn Server::serve(self : Server, path : String) -> Int {
  guard path != "" else { return 400 }
  if path == "/" {
    self.hits = self.hits + 1
  } else {
    self.hits = self.hits + 2
  }
  match path.length() {
    0 => 404
    n if n > 100 => 414
    n => self.hits + n
  }
}

///|
/// Stops the server, at once when forced to.
pub fn Server::stop(self : Server, force~ : Bool = false) -> Unit {
  if force {
    self.hits = 0
  }
  while self.hits > 1000 {
    self.hits = self.hits - 1000
  }
  self.hits = self.hits - 1
}

///|
/// What no caller asks.
pub fn Server::unused(self : Server) -> Int {
  self.hits * 7
}

///|
/// The most requests a server answers.
pub let limit : Int = 100
