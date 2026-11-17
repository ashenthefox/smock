// The gRPC side of the HTTP/2 harness: a unary call over moonhttp's
// client-side `Conn`, as gRPC clients make one, and its reply read frame by
// frame, trailers included. Messages are framed here, by hand, and come
// from protoc-encoded fixtures, so the tests never check smock's codec
// against itself. It also holds what several gRPC test files share: the
// Descriptor sets and Definition files they serve, and what they read back
// from replies, the Journal and the status.

///|
/// The protoc-encoded fixtures of gRPC's helloworld.proto.
let hello_request_path : String = "fixtures/protobuf/helloworld/hello-request.binpb"

///|
let hello_reply_path : String = "fixtures/protobuf/helloworld/hello-reply.binpb"

///|
/// `message` framed as gRPC frames an uncompressed message: flag 0, then its
/// length in 4 octets, big-endian, then its octets.
fn framed(message : Bytes) -> Bytes {
  let n = message.length()
  let out = @buffer.Buffer(size_hint=n + 5)
  out.write_byte(b'\x00')
  out.write_byte((n >> 24).to_byte())
  out.write_byte((n >> 16).to_byte())
  out.write_byte((n >> 8).to_byte())
  out.write_byte(n.to_byte())
  out.write_bytes(message)
  out.to_bytes()
}

///|
/// A reply to a gRPC call as the client got it, frame by frame.
struct GrpcReply {
  /// The fields of the HEADERS that answered, `:status` included, in order.
  head : Array[(String, String)]
  /// The octets of each DATA frame, in order.
  data : Array[Bytes]
  /// The fields of the trailers, when they came.
  trailers : Array[(String, String)]?
  /// How the stream ended: `"end"`, `"reset <code>"` with the code's name,
  /// or `"closed"` when the connection closed first.
  ended : String
}

///|
/// Makes a gRPC call to `path` with `body`, by default the framed
/// HelloRequest `{name: "Tom"}`: POST with `content-type: <content_type>`,
/// by default `application/grpc`, and `te: trailers`, as gRPC clients send
/// it, then `headers`. Reads its reply.
async fn H2Client::call(
  self : H2Client,
  path : String,
  authority~ : String = "localhost",
  content_type~ : String = "application/grpc",
  headers~ : Array[(String, String)] = [],
  body? : Bytes,
) -> GrpcReply {
  let body = match body {
    Some(body) => body
    None => framed(@fs.read_file(hello_request_path).binary())
  }
  let stream = self.send(
    "POST",
    path,
    authority~,
    headers=[("content-type", content_type), ("te", "trailers"), ..headers],
    body~,
  )
  self.reply(stream)
}

///|
/// Starts a call to SayHello for each of `calls`, in order, and sends them
/// all in one write, without reading their replies. Each is a POST of the
/// framed HelloRequest `{name: "Tom"}` with `content-type: application/grpc`
/// and `te: trailers`, as `H2Client::call` makes it, then the call's own
/// headers. smock reads the calls together, so the order of their replies
/// is smock's alone: it does not depend on how soon the test got round to
/// sending each. Returns the calls' streams, in order.
async fn H2Client::start_calls(
  self : H2Client,
  calls : Array[Array[(String, String)]],
) -> Array[Int32] {
  let body = framed(@fs.read_file(hello_request_path).binary())
  let streams = calls.map(headers => {
    let fields = [
      @header.Header::of(":method", "POST"),
      @header.Header::of(":scheme", "http"),
      @header.Header::of(":path", "/helloworld.Greeter/SayHello"),
      @header.Header::of(":authority", "localhost"),
      @header.Header::of("content-type", "application/grpc"),
      @header.Header::of("te", "trailers"),
    ]
    for header in headers {
      fields.push({
        name: @utf8.encode(header.0),
        value: @utf8.encode(header.1),
      })
    }
    let stream = self.conn.next_stream()
    self.conn.headers(stream, fields)
    self.conn.data(stream, body, end=true)
    stream
  })
  self.flush()
  streams
}

///|
/// Reads the reply on `stream` until the stream ends, is reset or the
/// connection closes.
async fn H2Client::reply(self : H2Client, stream : Int32) -> GrpcReply {
  let head = []
  let data = []
  let mut trailers = None
  let fields_of = (fields : Array[@header.Header]) => {
    fields.map(field => {
      (@utf8.decode_lossy(field.name), @utf8.decode_lossy(field.value))
    })
  }
  for ;; {
    match self.stream_event(stream) {
      Response(fields~, ..) => head.append(fields_of(fields))
      Data(data=octets, ..) => data.push(octets)
      Trailers(fields~, ..) => trailers = Some(fields_of(fields))
      End(_) => return { head, data, trailers, ended: "end", }
      Reset(code~, ..) =>
        return { head, data, trailers, ended: "reset \{error_name(code)}", }
      Closed => return { head, data, trailers, ended: "closed", }
      _ => ()
    }
  }
}

///|
/// The reply as a test shows it: `HEADERS` and each of its fields, with a
/// `date` that is the current time shown as `<now>`; `DATA` and the octets
/// of each DATA frame in hex; `TRAILERS` and their fields, when they came;
/// then how the stream ended.
fn GrpcReply::render(self : GrpcReply) -> String {
  let out = StringBuilder()
  out.write_string("HEADERS\n")
  for field in self.head {
    out.write_string("  \{shown_field(field.0, field.1)}\n")
  }
  for octets in self.data {
    out.write_string("DATA \{hex(octets)}\n")
  }
  if self.trailers is Some(trailers) {
    out.write_string("TRAILERS\n")
    for field in trailers {
      out.write_string("  \{field.0}: \{field.1}\n")
    }
  }
  out.write_string("(\{self.ended})")
  out.to_string()
}

///|
/// `octets` in lower-case hex.
fn hex(octets : Bytes) -> String {
  let out = StringBuilder()
  for octet in octets {
    out.write_string(octet.to_int().to_string(radix=16).pad_start(2, '0'))
  }
  out.to_string()
}

///|
/// Runs `f` with a definitions directory holding `files` and the set of
/// gRPC's helloworld.proto at `files/greeter.binpb`.
async fn with_greeter_set(
  files : Array[(String, String)],
  f : async (String) -> Unit,
) -> Unit {
  with_definitions(files, dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    f(dir)
  })
}

///|
/// The last entry of the Journal, as `journal_shown` shows it.
async fn Smock::last_entry(self : Smock) -> String {
  let (_, journal) = self.journal()
  guard journal is Object({ "entries": Array(entries), .. }) &&
    entries.last() is Some(entry) else {
    return "no entry"
  }
  journal_shown(entry).stringify()
}

///|
/// The set protoc builds from gRPC's helloworld.proto.
let greeter_set_path : String = "fixtures/protobuf/helloworld/greeter.binpb"

///|
/// The same set, rebuilt with one more field in HelloReply.
let greeter_v2_set_path : String = "fixtures/protobuf/helloworld-v2/greeter.binpb"

///|
/// Writes `bytes` to `dir/path`, replacing what is there.
async fn write_bytes(dir : String, path : String, bytes : Bytes) -> Unit {
  @fs.write_file("\{dir}/\{path}", bytes)
}

///|
/// The fields of a gRPC call with the method `meth` to `path` at
/// `localhost`: `content-type: <content_type>`, by default
/// `application/grpc`, and `te: trailers`, unless `te` is false, then
/// `more`.
fn checked_call(
  meth : String,
  path~ : String = "/helloworld.Greeter/SayHello",
  content_type~ : String = "application/grpc",
  te~ : Bool = true,
  more~ : Array[(String, String)] = [],
) -> Array[(String, String)] {
  let fields = request_fields(meth, path, "localhost")
  fields.push(("content-type", content_type))
  if te {
    fields.push(("te", "trailers"))
  }
  fields.append(more)
  fields
}

///|
/// The directory of the collections fixtures.
let collections_dir : String = "fixtures/protobuf/collections"

///|
/// Runs `f` with a definitions directory holding `shelf.yaml`, whose text
/// is `yaml`, and the set of collections.proto at
/// `files/collections.binpb`.
async fn with_collections_set(
  yaml : String,
  f : async (String) -> Unit,
) -> Unit {
  with_definitions([("shelf.yaml", yaml)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/collections.binpb",
      @fs.read_file("\{collections_dir}/collections.binpb").binary(),
    )
    f(dir)
  })
}

///|
/// The directory of the users fixtures.
let users_dir : String = "fixtures/protobuf/users"

///|
/// The framed message that protoc encoded from `<name>.txtpb` in the users
/// fixtures.
async fn users_message(name : String) -> Bytes {
  framed(@fs.read_file("\{users_dir}/\{name}.binpb").binary())
}

///|
/// Runs `f` with a definitions directory holding `users.yaml`, whose text
/// is `yaml`, and the set of users.proto at `files/users.binpb`.
async fn with_users_set(yaml : String, f : async (String) -> Unit) -> Unit {
  with_definitions([("users.yaml", yaml)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/users.binpb",
      @fs.read_file("\{users_dir}/users.binpb").binary(),
    )
    f(dir)
  })
}

///|
/// The `grpc-status` of `reply`: from its trailers, or from its HEADERS
/// when it is Trailers-Only.
fn GrpcReply::status(self : GrpcReply) -> String {
  let fields = match self.trailers {
    Some(trailers) => trailers
    None => self.head
  }
  for field in fields {
    if field.0 == "grpc-status" {
      return field.1
    }
  }
  "none"
}

///|
/// Starts a call to SayHello with the framed HelloRequest `{name: "Tom"}`,
/// as `H2Client::call` sends it, with `grpc-timeout: <timeout>` when given,
/// then `headers`, and returns its stream without reading the reply.
async fn H2Client::start_call(
  self : H2Client,
  timeout? : String,
  headers~ : Array[(String, String)] = [],
) -> Int32 {
  let fields = [("content-type", "application/grpc"), ("te", "trailers")]
  if timeout is Some(timeout) {
    fields.push(("grpc-timeout", timeout))
  }
  self.send(
    "POST",
    "/helloworld.Greeter/SayHello",
    authority="localhost",
    headers=[..fields, ..headers],
    body=framed(@fs.read_file(hello_request_path).binary()),
  )
}

///|
/// The set of fixtures/protobuf/details/: helloworld.proto and
/// error_details.proto.
let details_set_path : String = "fixtures/protobuf/details/details.binpb"

///|
/// The framed HelloRequest `{name: "Ann"}`, as protoc encodes it.
async fn hello_ann() -> Bytes {
  framed(@fs.read_file("fixtures/protobuf/details/hello-ann.binpb").binary())
}

///|
/// Runs `f` with a definitions directory holding `details.yaml`, which
/// declares the Mock `greeter`, the Default Mock, whose set is
/// details.binpb, then holds `stubs`, the lines of its `stubs` array; and
/// with the set at `files/details.binpb`.
async fn with_details(stubs : String, f : async (String) -> Unit) -> Unit {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    default: true
    #|    grpc: { descriptorSet: details.binpb }
    #|stubs:
    #|
  with_definitions([("details.yaml", yaml + stubs)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/details.binpb",
      @fs.read_file(details_set_path).binary(),
    )
    f(dir)
  })
}

///|
/// An HTTP/2 client of smock's plain port for `"h2c"`, or of its TLS port
/// for `"h2"`.
async fn Smock::h2_on(self : Smock, port : String) -> H2Client {
  if port == "h2c" {
    self.h2c()
  } else {
    self.h2()
  }
}

///|
/// The reply in short: its `:status`, its `grpc-status` and `grpc-message`,
/// from the trailers or from a Trailers-Only answer's HEADERS, how many DATA
/// frames came, and how the stream ended.
fn GrpcReply::outline(self : GrpcReply) -> String {
  let out = []
  let fields = match self.trailers {
    Some(trailers) => [..self.head, ..trailers]
    None => self.head
  }
  for field in fields {
    if field.0 is (":status" | "grpc-status" | "grpc-message") {
      out.push("\{field.0}: \{field.1}")
    }
  }
  out.push("\{self.data.length()} DATA")
  "\{out.join(", ")} (\{self.ended})"
}

///|
/// The entries of the Journal of `session`, or of the no-Session space,
/// one per line, as `answers` shows them: the Stub, the HTTP status and the
/// gRPC status, then the template error, if any.
async fn Smock::calls_of(self : Smock, session? : String) -> String {
  let (_, page) = self.journal(session?)
  answers(page)
}

///|
/// The fields of a gRPC call to `path` at `authority`, as gRPC clients send
/// them, with `content-type: <content_type>`, by default
/// `application/grpc`, then `more`.
fn call_fields(
  path : String,
  authority : String,
  content_type~ : String = "application/grpc",
  more~ : Array[(String, String)] = [],
) -> Array[(String, String)] {
  let fields = request_fields("POST", path, authority)
  fields.push(("content-type", content_type))
  fields.push(("te", "trailers"))
  fields.append(more)
  fields
}

///|
/// The Journal's entries, one per line: the Mock, the target, the body's
/// data and size, the HTTP status, the gRPC status and the Stub of the Near
/// miss, each as JSON.
async fn calls_journaled(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "mock": mock,
          "request": Object(
            {
              "target": String(target),
              "body": Object({ "data": data, "size": size, .. }),
              ..
            }
          ),
          "status": status,
          "grpcStatus": grpc_status,
          "nearMiss": near_miss,
          ..
        }
      ) else {
      fail("not a gRPC call's entry: \{entry.stringify()}")
    }
    let near = match near_miss {
      Object({ "stub": stub, .. }) => stub.stringify()
      _ => "null"
    }
    out.push(
      "\{mock.stringify()} \{target} \{data.stringify()}/\{size.stringify()} \{status.stringify()} \{grpc_status.stringify()} near miss \{near}",
    )
  }
  out.join("\n")
}

///|
/// The entries of `page`, a Journal page, one per line: the Stub, the HTTP
/// status and the gRPC status, each as JSON, `-` for a member the entry
/// does not have, then the `x-tenant` metadata the call sent, if any, and
/// the template error, if any.
fn answers(page : Json) -> String raise {
  guard page is Object({ "entries": Array(entries), .. }) else {
    fail("not a Journal page: \{page.stringify()}")
  }
  let lines = []
  for entry in entries {
    guard entry is Object(members) else { fail("not an entry") }
    let shown = (name : String) => {
      members.get(name).map_or("-", value => value.stringify())
    }
    let mut tenant = ""
    if members.get("request") is Some(Object({ "headers": Array(headers), .. })) {
      for header in headers {
        if header
          is Object({ "name": String("x-tenant"), "value": String(value), .. }) {
          tenant = " x-tenant=\{value}"
        }
      }
    }
    let error = match members.get("templateError") {
      Some(Null) | None => ""
      Some(error) => " templateError=\{error.stringify()}"
    }
    lines.push(
      "\{shown("stub")} \{shown("status")} \{shown("grpcStatus")}\{tenant}\{error}",
    )
  }
  lines.join("\n")
}

///|
/// The directory of the limits fixtures.
let limits_dir : String = "fixtures/protobuf/limits"

///|
/// Each Journal entry, oldest first, one per line: the Stub that answered
/// it, or `null`, then its body as the Stubs saw it.
async fn Smock::bodies(self : Smock) -> String {
  guard self.journal() is (200, Object({ "entries": Array(entries), .. })) else {
    fail("no Journal")
  }
  let lines = []
  for entry in entries {
    guard entry
      is Object(
        {
          "stub": stub,
          "request": Object(
            { "body": Object({ "data": String(data), .. }), .. }
          ),
          ..
        }
      ) else {
      fail("not an entry: \{entry.stringify()}")
    }
    lines.push("\{stub.stringify()}: \{data}")
  }
  lines.join("\n")
}

///|
/// The set of fixtures/protobuf/replies/replies.proto.
let replies_set_path : String = "fixtures/protobuf/replies/replies.binpb"

///|
/// The entries of the Journal, one per line: the Mock, the Stub, the gRPC
/// status and the body's data and size, each as JSON.
async fn answered_by(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "mock": mock,
          "stub": stub,
          "grpcStatus": grpc_status,
          "request": Object(
            { "body": Object({ "data": data, "size": size, .. }), .. }
          ),
          ..
        }
      ) else {
      fail("not an entry: \{entry.stringify()}")
    }
    out.push(
      "\{mock.stringify()} \{stub.stringify()} \{grpc_status.stringify()} \{data.stringify()}/\{size.stringify()}",
    )
  }
  out.join("\n")
}

///|
/// The Definition file of the Default Mock `greeter`, whose set is
/// `greeter.binpb`, with one Stub on SayHello for `version`, 1 or 2, of
/// helloworld.proto: `hello-v1` answers every call; `hello-v2` answers a
/// call whose message has the field `version`, which only version 2's set
/// decodes, and replies with it, which only version 2's set encodes, so
/// version 1's set refuses this file.
fn versioned_greeter(version : Int32) -> String {
  let stub = if version == 1 {
    (
      #|  - id: hello-v1
      #|    mock: greeter
      #|    request: { path: /helloworld.Greeter/SayHello }
      #|    response: { json: { message: Hello from v1 } }
    )
  } else {
    (
      #|  - id: hello-v2
      #|    mock: greeter
      #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { version: 2 } } }
      #|    response: { json: { message: Hello from v2, version: 2 } }
    )
  }
  (
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|
  ) +
  stub
}

///|
/// Waits until a reload after the status `before` swaps in a new
/// definition set, through at most two reloads that do not, and returns
/// the status then.
async fn Smock::swapped(
  self : Smock,
  before : Map[String, Json],
) -> Map[String, Json] {
  let mut last = before
  for _ in 0..<3 {
    let status = self.reloaded(last)
    if status.get("lastReload")
      is Some(Object({ "result": String("swapped"), .. })) {
      return status
    }
    last = status
  }
  fail("no reload swapped: \{last_reload(last)}")
}

///|
/// Moves the definitions in `dir` to `version`, 1 or 2, of helloworld.proto
/// and its Stub (`versioned_greeter`), and waits until a reload swaps them
/// in. The file version 1's set refuses is written while version 1's set is
/// there, so that no reload serves a set with the Stub of the other
/// version: to version 2, the Definition file first, then the set; to
/// version 1, the set first.
async fn Smock::switch_to(self : Smock, dir : String, version : Int32) -> Unit {
  let before = self.status()
  let set = if version == 1 { greeter_set_path } else { greeter_v2_set_path }
  let write_file = () => {
    @fs.write_file("\{dir}/greeter.yaml", versioned_greeter(version))
  }
  let write_set = () => {
    write_bytes(dir, "files/greeter.binpb", @fs.read_file(set).binary())
  }
  if version == 1 {
    write_set()
    write_file()
  } else {
    write_file()
    write_set()
  }
  let _ = self.swapped(before)
}

///|
/// The value of the field `name` of the reply, as a client reads its
/// status: from its trailers, or from its one HEADERS block when the reply
/// is Trailers-Only.
fn GrpcReply::status_field(self : GrpcReply, name : String) -> String? {
  let fields = match self.trailers {
    Some(trailers) => trailers
    None => self.head
  }
  for field in fields {
    if field.0 == name {
      return Some(field.1)
    }
  }
  None
}

///|
/// How the client reads the reply's end: its `grpc-status`, whether it came
/// as Trailers-Only or after a reply message, and its `grpc-message`, as
/// sent and as the client percent-decodes it, when it has one.
fn GrpcReply::status_line(self : GrpcReply) -> String raise {
  let form = if self.trailers is None && self.data.is_empty() {
    "trailers-only"
  } else {
    "message, then trailers"
  }
  let status = self.status_field("grpc-status").unwrap_or("none")
  let line = "grpc-status \{status}, \{form}"
  match self.status_field("grpc-message") {
    Some(sent) =>
      "\{line}\n  sent: \{sent}\n  decoded: \{@percent.decode(sent).escape()}"
    None => line
  }
}

///|
/// Runs `f` with a definitions directory holding `greeter.yaml` and the set
/// of gRPC's helloworld.proto at `files/greeter.binpb`.
async fn with_greeter(yaml : String, f : async (String) -> Unit) -> Unit {
  with_definitions([("greeter.yaml", yaml)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    f(dir)
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and the gRPC Stub
/// `hello` of #205's example.
let greeter_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }

///|
/// The directory of the wellknown fixtures.
let wellknown_dir : String = "fixtures/protobuf/wellknown"

///|
/// The message that protoc encoded from `<name>.txtpb` in the wellknown
/// fixtures, framed.
async fn wellknown_message(name : String) -> Bytes {
  framed(@fs.read_file("\{wellknown_dir}/\{name}.binpb").binary())
}

///|
/// Runs `f` with a definitions directory holding `leases.yaml`, which
/// declares the Mock `leases`, the Default Mock, whose set is
/// wellknown.proto's, then holds `stubs`, the lines of its `stubs` array;
/// and with the set at `files/wellknown.binpb`.
async fn with_leases(stubs : String, f : async (String) -> Unit) -> Unit {
  let yaml =
    #|mocks:
    #|  - name: leases
    #|    default: true
    #|    grpc: { descriptorSet: wellknown.binpb }
    #|stubs:
    #|
  with_definitions([("leases.yaml", yaml + stubs)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/wellknown.binpb",
      @fs.read_file("\{wellknown_dir}/wellknown.binpb").binary(),
    )
    f(dir)
  })
}
