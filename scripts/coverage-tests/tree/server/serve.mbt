///|
/// The names of the ports, in the order they open.
let port_names : Array[String] = names("plain tls")

///|
async fn[S : @io.Reader] Server::serve(self : Server, stream : S) -> Unit {
  let request = read(stream)
  self.answer(request)
}

///|
impl Show for Server with fn output(self, logger) {
  logger.write_string("« \{self.name()} »")
}
