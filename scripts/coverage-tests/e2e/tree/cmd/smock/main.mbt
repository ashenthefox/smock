///|
/// Runs a server, as smock's binary does, in the tests of
/// scripts/coverage-e2e.py.
fn main {
  let server = @server.Server::new()
  let answer = (path : String) => server.serve(path)
  let unused_handler = fn(code : Int) { code + 1 }
  ignore(answer("/x"))
  ignore(unused_handler)
  server.stop()
}
