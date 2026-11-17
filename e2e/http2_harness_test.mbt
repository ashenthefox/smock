// The HTTP/2 side of the Seam 2 harness, for every HTTP/2 test: an HTTP/2
// client, which is moonhttp's client-side `Conn` over a TCP socket to the
// plain port (h2c) or over TLS to the TLS port (h2), and raw-frame helpers,
// which send any frame, malformed ones included, with none of the checks a
// client makes, and read frames back. Over TLS, the octets go through the
// OpenSSL bindings' client side, which offers ALPN: moonbitlang/async's TLS
// client offers none. It also holds what several HTTP/2 test files share:
// the Definition files they serve, and what they read back from responses,
// frames and the Journal.

///|
/// A TLS connection to smock's TLS port through the OpenSSL bindings'
/// client side. OpenSSL works on memory only, so this moves the octets
/// between it and the socket.
struct TlsClient {
  tcp : @socket.Tcp
  tls : @openssl.Connection
  /// What each socket read reads into.
  input : FixedArray[Byte]
}

///|
/// A TLS handshake that smock failed with an alert, by the alert's code,
/// such as 120 for no_application_protocol (RFC 8446, section 6). The code
/// is the same in every OpenSSL version; OpenSSL's text for it is not, and
/// before 3.4 there is none for no_application_protocol.
suberror HandshakeAlert {
  HandshakeAlert(Int32)
}

///|
/// Opens a TLS connection to smock's TLS port that offers the protocols in
/// `alpn` by ALPN, or no ALPN when it is empty, sends `server_name` by SNI
/// and checks smock's certificate for it, trusting only the PEM
/// certificates in `trusted` (by default the test root CA). A handshake
/// that fails raises `HandshakeAlert` when smock sent an alert, and
/// OpenSSL's reason otherwise.
async fn Smock::tls(
  self : Smock,
  alpn~ : Array[String],
  server_name~ : String = "localhost",
  trusted~ : String = @testcerts.root_ca,
) -> TlsClient {
  let tls = @openssl.ClientConfig(trusted=@utf8.encode(trusted), alpn~).connect(
    server_name~,
  )
  let tcp = @socket.Tcp::connect(
    @socket.Addr::parse("127.0.0.1:\{self.tls_port}"),
  )
  errdefer tcp.close()
  let client = { tcp, tls, input: FixedArray::make(16 * 1024, b'\x00'), }
  let handshake = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let done = tls.handshake() catch {
        err =>
          match tls.alert_received() {
            Some(alert) => raise HandshakeAlert(alert)
            None => raise err
          }
      }
      client.flush()
      if done {
        break
      }
      let n = tcp.read(client.input)
      if n == 0 {
        fail("smock closed the connection during the handshake")
      }
      tls.receive(client.input.unsafe_reinterpret_as_bytes()[:n])
    }
  })
  guard handshake is Some(_) else { fail("no TLS handshake in time") }
  client
}

///|
/// The protocol ALPN selected: `none` when none was.
fn TlsClient::protocol(self : TlsClient) -> String {
  self.tls.alpn_protocol().unwrap_or("none")
}

///|
/// Sends what OpenSSL has written for smock.
async fn TlsClient::flush(self : TlsClient) -> Unit {
  let output = self.tls.take_output()
  if output.length() > 0 {
    self.tcp.write(output)
  }
}

///|
/// Encrypts `data` and sends it.
async fn TlsClient::write(self : TlsClient, data : BytesView) -> Unit {
  self.tls.write(data)
  self.flush()
}

///|
/// Reads plaintext into `buf`, and returns how many octets came: 0 once
/// smock has ended the connection, with close_notify, a FIN or a reset.
async fn TlsClient::read(self : TlsClient, buf : FixedArray[Byte]) -> Int32 {
  for ;; {
    match self.tls.read(buf, offset=0, max_len=buf.length()) {
      Data(n) => {
        self.flush()
        return n
      }
      Closed => return 0
      NeedInput => {
        self.flush()
        let n = self.tcp.read(self.input) catch { _ => 0 }
        if n == 0 {
          return 0
        }
        self.tls.receive(self.input.unsafe_reinterpret_as_bytes()[:n])
      }
    }
  }
}

///|
/// Reads plaintext until smock ends the connection, and returns all of it.
async fn TlsClient::read_all(self : TlsClient) -> Bytes {
  let buf = FixedArray::make(16 * 1024, b'\x00')
  let out = @buffer.Buffer()
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let n = self.read(buf)
      if n == 0 {
        break
      }
      out.write_bytes(buf.unsafe_reinterpret_as_bytes()[:n])
    }
  })
  guard result is Some(_) else { fail("the TLS connection stayed open") }
  out.to_bytes()
}

///|
/// Closes the TCP connection at once, with no close_notify.
fn TlsClient::close(self : TlsClient) -> Unit {
  self.tcp.close()
}

///|
/// What an HTTP/2 test client talks over: TCP to the plain port, or TLS to
/// the TLS port.
enum Wire {
  Cleartext(@socket.Tcp)
  Encrypted(TlsClient)
}

///|
/// Sends `data`: as it is over TCP, encrypted over TLS.
async fn Wire::write(self : Wire, data : BytesView) -> Unit {
  match self {
    Cleartext(tcp) => tcp.write(data)
    Encrypted(tls) => tls.write(data)
  }
}

///|
/// Reads into `buf`, and returns how many octets came: 0 once smock has
/// ended the connection.
async fn Wire::read(self : Wire, buf : FixedArray[Byte]) -> Int32 {
  match self {
    Cleartext(tcp) => tcp.read(buf)
    Encrypted(tls) => tls.read(buf)
  }
}

///|
/// Closes the connection at once, sending nothing more.
fn Wire::close(self : Wire) -> Unit {
  match self {
    Cleartext(tcp) => tcp.close()
    Encrypted(tls) => tls.close()
  }
}

///|
/// An HTTP/2 connection to smock: moonhttp's client-side `Conn` over TCP to
/// the plain port by prior knowledge (h2c), or over TLS to the TLS port by
/// ALPN (h2). It sends the preface and its SETTINGS when it opens, hands
/// back every DATA octet it receives, so that smock's windows stay open,
/// and keeps the events of streams no one has asked about yet.
struct H2Client {
  wire : Wire
  conn : @http2.Conn
  /// What each read reads into.
  buf : FixedArray[Byte]
  /// The events read but not yet taken, oldest first.
  events : Array[@http2.Event]
}

///|
/// An HTTP/2 client over `wire`, which has sent nothing yet, with the
/// SETTINGS `settings`, by default moonhttp's.
fn H2Client::new(
  wire : Wire,
  settings~ : @http2.Settings = @http2.settings,
) -> H2Client {
  {
    wire,
    conn: @http2.Conn::new(Client, settings~),
    buf: FixedArray::make(16 * 1024, b'\x00'),
    events: [],
  }
}

///|
/// Opens an HTTP/2 connection to smock's plain port and sends the preface
/// and the client's SETTINGS, `settings`, by default moonhttp's. With
/// `preface_in` greater than 0, the preface goes out in pieces of that many
/// octets, with a pause between them, so that smock reads it in parts.
async fn Smock::h2c(
  self : Smock,
  preface_in~ : Int32 = 0,
  settings~ : @http2.Settings = @http2.settings,
) -> H2Client {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.port}"))
  let client = H2Client::new(Cleartext(tcp), settings~)
  if preface_in > 0 {
    let opening = client.conn.take()
    let preface = @http2.preface.length()
    let mut at = 0
    while at < preface {
      let end = if at + preface_in < preface {
        at + preface_in
      } else {
        preface
      }
      tcp.write(opening[at:end])
      @async.sleep(50)
      at = end
    }
    tcp.write(opening[preface:])
  } else {
    client.flush()
  }
  client
}

///|
/// Opens an HTTP/2 connection to smock's TLS port, a TLS connection that
/// offers `h2` alone by ALPN, as `Smock::tls` opens it with `server_name`
/// and `trusted`, and sends the preface and the client's SETTINGS. Fails
/// unless ALPN selected `h2`.
async fn Smock::h2(
  self : Smock,
  server_name~ : String = "localhost",
  trusted~ : String = @testcerts.root_ca,
) -> H2Client {
  let tls = self.tls(alpn=["h2"], server_name~, trusted~)
  if tls.protocol() != "h2" {
    tls.close()
    fail("ALPN selected \{tls.protocol()}, not h2")
  }
  H2Client::over(Encrypted(tls))
}

///|
/// An HTTP/2 client over `wire`, once it has sent the preface and its
/// SETTINGS.
async fn H2Client::over(wire : Wire) -> H2Client {
  let client = H2Client::new(wire)
  client.flush()
  client
}

///|
/// Closes the connection at once, with no GOAWAY.
fn H2Client::close(self : H2Client) -> Unit {
  self.wire.close()
}

///|
/// Writes what the client's `Conn` has queued.
async fn H2Client::flush(self : H2Client) -> Unit {
  let out = self.conn.take()
  if out.length() > 0 {
    self.wire.write(out)
  }
}

///|
/// The next event from smock, read from the socket when the `Conn` needs
/// more: `Closed` once smock has closed the connection. DATA is handed back
/// as it is read.
async fn H2Client::read_event(self : H2Client) -> @http2.Event {
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let event = self.conn.next()
      match event {
        NeedData => {
          self.flush()
          let n = self.wire.read(self.buf) catch { _ => 0 }
          self.conn.receive(self.buf.unsafe_reinterpret_as_bytes()[:n])
        }
        Data(stream~, data~) => {
          self.conn.acknowledge(stream, data.length())
          break event
        }
        _ => break event
      }
    }
  })
  guard result is Some(event) else { fail("no HTTP/2 event in time") }
  event
}

///|
/// The next event about `stream`, keeping the events of other streams for
/// later, or `Closed` once smock has closed the connection.
async fn H2Client::stream_event(
  self : H2Client,
  stream : Int32,
) -> @http2.Event {
  for i, event in self.events {
    if event_stream(event) == Some(stream) {
      self.events.remove(i) |> ignore
      return event
    }
  }
  for ;; {
    let event = self.read_event()
    if event is Closed || event_stream(event) == Some(stream) {
      return event
    }
    if event_stream(event) is Some(_) {
      self.events.push(event)
    }
  }
}

///|
/// How many of the events `client` has read and kept for later are about
/// `stream`. Once the client has read a stream's response with
/// `stream_event`, this tells whether anything of another stream came
/// before that response ended.
fn H2Client::kept_for(self : H2Client, stream : Int32) -> Int32 {
  let mut n = 0
  for event in self.events {
    if event_stream(event) == Some(stream) {
      n += 1
    }
  }
  n
}

///|
/// The stream an event is about, if it is about one.
fn event_stream(event : @http2.Event) -> Int32? {
  match event {
    Response(stream~, ..)
    | Informational(stream~, ..)
    | Trailers(stream~, ..)
    | Data(stream~, ..)
    | End(stream~)
    | Reset(stream~, ..) => Some(stream)
    WindowUpdated(stream~, ..) if stream != 0 => Some(stream)
    _ => None
  }
}

///|
/// Opens a new stream with a request: `:method` `meth`, `:scheme` `http`,
/// `:path` `path` and `:authority` `authority` when given, then `headers`
/// in order. Sends `body`, when given, within the windows smock gives, and
/// ends the stream unless `end` is false. Returns the stream's ID.
async fn H2Client::send(
  self : H2Client,
  meth : String,
  path : String,
  authority? : String,
  headers~ : Array[(String, String)] = [],
  body? : Bytes,
  end~ : Bool = true,
) -> Int32 {
  let fields = [
    @header.Header::of(":method", meth),
    @header.Header::of(":scheme", "http"),
    @header.Header::of(":path", path),
  ]
  if authority is Some(authority) {
    fields.push(@header.Header::of(":authority", authority))
  }
  for header in headers {
    fields.push({ name: @utf8.encode(header.0), value: @utf8.encode(header.1), })
  }
  let stream = self.conn.next_stream()
  match body {
    None => self.conn.headers(stream, fields, end~)
    Some(body) => {
      self.conn.headers(stream, fields)
      self.send_data(stream, body, end~)
    }
  }
  self.flush()
  stream
}

///|
/// Sends `body` on `stream`, as much at a time as the windows allow,
/// waiting for smock to widen them, and ends the stream unless `end` is
/// false.
async fn H2Client::send_data(
  self : H2Client,
  stream : Int32,
  body : Bytes,
  end~ : Bool = true,
) -> Unit {
  let mut at = 0
  while at < body.length() {
    let room = self.conn.window(stream)
    if room == 0 {
      self.flush()
      match self.read_event() {
        Closed => fail("smock closed the connection while a body was sent")
        event => if event_stream(event) is Some(_) { self.events.push(event) }
      }
      continue
    }
    let n = if body.length() - at < room { body.length() - at } else { room }
    self.conn.data(stream, body[at:at + n], end=end && at + n == body.length())
    at += n
  }
  if body.length() == 0 && end {
    self.conn.end(stream)
  }
  self.flush()
}

///|
/// Sends a request as `send` does and reads its response.
async fn H2Client::request(
  self : H2Client,
  meth : String,
  path : String,
  authority? : String,
  headers~ : Array[(String, String)] = [],
  body? : Bytes,
) -> H2Response {
  self.response(self.send(meth, path, authority?, headers~, body?))
}

///|
/// A response on one stream as the client got it.
struct H2Response {
  /// The status, or 0 when none came.
  status : Int32
  /// The header fields, pseudo-header fields left out, in the order they
  /// came.
  headers : Array[(String, String)]
  body : Bytes
  /// How the stream ended: `"end"`, `"reset <code>"` with the code's name,
  /// or `"closed"` when the connection closed first.
  ended : String
}

///|
/// Reads the response on `stream` until the stream ends, is reset or the
/// connection closes.
async fn H2Client::response(self : H2Client, stream : Int32) -> H2Response {
  let mut status = 0
  let headers = []
  let body = @buffer.Buffer()
  for ;; {
    match self.stream_event(stream) {
      Response(fields~, ..) =>
        for field in fields {
          let (name, value) = (
            @utf8.decode_lossy(field.name),
            @utf8.decode_lossy(field.value),
          )
          if name == ":status" {
            status = @string.parse_int(value)
          } else {
            headers.push((name, value))
          }
        }
      Data(data~, ..) => body.write_bytes(data)
      End(_) => return { status, headers, body: body.to_bytes(), ended: "end", }
      Reset(code~, ..) =>
        return {
          status,
          headers,
          body: body.to_bytes(),
          ended: "reset \{error_name(code)}",
        }
      Closed =>
        return { status, headers, body: body.to_bytes(), ended: "closed", }
      _ => ()
    }
  }
}

///|
/// The response as a test shows it: the status, each header field, with a
/// `date` that is the current time shown as `<now>` (`mask_date`), an
/// empty line and the body, then how the stream ended when it did not end
/// as usual.
fn H2Response::render(self : H2Response) -> String {
  let out = StringBuilder()
  out.write_string("\{self.status}\n")
  for header in self.headers {
    out.write_string("\{shown_field(header.0, header.1)}\n")
  }
  out.write_string("\n")
  out.write_string(@utf8.decode_lossy(self.body))
  if self.ended != "end" {
    out.write_string("\n(\{self.ended})")
  }
  out.to_string()
}

///|
/// A field received from smock as a test shows it, `name: value`, with a
/// `date` that is the current time shown as `<now>` (`mask_date`).
fn shown_field(name : String, value : String) -> String {
  if name == "date" && mask_date("Date: \{value}") == "Date: <now>" {
    "date: <now>"
  } else {
    "\{name}: \{value}"
  }
}

///|
/// The name RFC 9113, section 7, gives an error code.
fn error_name(code : Int32) -> String {
  match code {
    0x0 => "NO_ERROR"
    0x1 => "PROTOCOL_ERROR"
    0x2 => "INTERNAL_ERROR"
    0x3 => "FLOW_CONTROL_ERROR"
    0x4 => "SETTINGS_TIMEOUT"
    0x5 => "STREAM_CLOSED"
    0x6 => "FRAME_SIZE_ERROR"
    0x7 => "REFUSED_STREAM"
    0x8 => "CANCEL"
    0x9 => "COMPRESSION_ERROR"
    0xa => "CONNECT_ERROR"
    0xb => "ENHANCE_YOUR_CALM"
    0xc => "INADEQUATE_SECURITY"
    0xd => "HTTP_1_1_REQUIRED"
    _ => "0x\{code.to_string(radix=16)}"
  }
}

///|
/// A connection to smock's plain port, or by ALPN `h2` to its TLS port,
/// that sends frames exactly as a test builds them, with moonhttp's frame
/// encoder and header blocks from its HPACK encoder, and none of the checks
/// a client makes, so that malformed requests can be sent; and reads frames
/// back, decoding their header blocks with its HPACK decoder.
struct RawH2 {
  wire : Wire
  encoder : @hpack.Encoder
  decoder : @hpack.Decoder
  /// What each read reads into.
  buf : FixedArray[Byte]
  /// The octets received and not yet read as frames.
  mut received : Bytes
}

///|
/// Opens a connection to smock's plain port, or with `tls` to its TLS port,
/// offering `h2` alone by ALPN, and sends the preface and, unless
/// `settings` is false, an empty SETTINGS frame. With `preface` false, it
/// sends neither, so that a test can send the preface itself.
async fn Smock::raw_h2(
  self : Smock,
  settings~ : Bool = true,
  tls~ : Bool = false,
  preface~ : Bool = true,
) -> RawH2 {
  let wire = if tls {
    let tls = self.tls(alpn=["h2"])
    if tls.protocol() != "h2" {
      tls.close()
      fail("ALPN selected \{tls.protocol()}, not h2")
    }
    Encrypted(tls)
  } else {
    Cleartext(
      @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.port}")),
    )
  }
  let raw = {
    wire,
    encoder: @hpack.Encoder::new(),
    decoder: @hpack.Decoder::new(),
    buf: FixedArray::make(16 * 1024, b'\x00'),
    received: b"",
  }
  if !preface {
    return raw
  }
  wire.write(@http2.preface)
  if settings {
    raw.send([Settings(params=[], ack=false)])
  }
  raw
}

///|
/// Closes the connection at once, with no GOAWAY.
fn RawH2::close(self : RawH2) -> Unit {
  self.wire.close()
}

///|
/// Sends `frames`, in one write.
async fn RawH2::send(self : RawH2, frames : Array[@http2.Frame]) -> Unit {
  let out = @buffer.Buffer()
  for frame in frames {
    out.write_bytes(frame.encode())
  }
  self.wire.write(out.to_bytes())
}

///|
/// Sends `bytes` as they are.
async fn RawH2::send_bytes(self : RawH2, bytes : Bytes) -> Unit {
  self.wire.write(bytes)
}

///|
/// The header block of `fields`, names and values as UTF-8, from the
/// connection's HPACK encoder, for a HEADERS or CONTINUATION frame.
fn RawH2::block(self : RawH2, fields : Array[(String, String)]) -> Bytes {
  let headers = fields.map(field => @header.Header::{
    name: @utf8.encode(field.0),
    value: @utf8.encode(field.1),
  })
  self.encoder.encode(headers[:])
}

///|
/// The fields of a header block received from smock, as text, decoded
/// with the connection's HPACK decoder.
fn RawH2::fields(self : RawH2, block : Bytes) -> Array[(String, String)] raise {
  self.decoder
  .decode(block[:])
  .map(field => {
    (@utf8.decode_lossy(field.name), @utf8.decode_lossy(field.value))
  })
}

///|
/// The next frame from smock, or `None` once smock has ended the
/// connection, by a FIN or a reset alike.
async fn RawH2::read_frame(self : RawH2) -> @http2.Frame? {
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let (frame, used) = @http2.decode(self.received) catch {
        Incomplete => {
          let n = self.wire.read(self.buf) catch { _ => 0 }
          guard n > 0 else { break None }
          self.received = self.received +
            self.buf.unsafe_reinterpret_as_bytes()[:n].to_owned()
          continue
        }
        err => fail("smock sent a frame that does not decode: \{err}")
      }
      self.received = self.received[used:].to_owned()
      break Some(frame)
    }
  })
  guard result is Some(frame) else { fail("no HTTP/2 frame in time") }
  frame
}

///|
/// Reads frames until smock ends the connection, and shows each as
/// `render_frame` does, one per line, then `closed`.
async fn RawH2::frames_until_end(self : RawH2) -> String {
  let out = []
  while self.read_frame() is Some(frame) {
    out.push(self.render_frame(frame))
  }
  out.push("closed")
  out.join("\n")
}

///|
/// Reads frames until one ends `stream` (DATA or HEADERS with END_STREAM,
/// or RST_STREAM) or smock ends the connection, and shows each as
/// `render_frame` does, one per line, with `closed` at the end of the
/// connection.
async fn RawH2::frames_until_stream_ends(
  self : RawH2,
  stream : Int32,
) -> String {
  let out = []
  for ;; {
    guard self.read_frame() is Some(frame) else {
      out.push("closed")
      break
    }
    out.push(self.render_frame(frame))
    match frame {
      Data(stream_id~, end_stream=true, ..)
      | Headers(stream_id~, end_stream=true, ..)
      | RstStream(stream_id~, ..) if stream_id == stream => break
      _ => ()
    }
  }
  out.join("\n")
}

///|
/// A frame as a test shows it: its type, its stream, its flags and what
/// it carries, header blocks decoded.
fn RawH2::render_frame(self : RawH2, frame : @http2.Frame) -> String {
  match frame {
    Data(stream_id~, data~, end_stream~, ..) =>
      "DATA \{stream_id}\{flag(end_stream, " END_STREAM")} \{data.length()} octets"
    Headers(stream_id~, fragment~, end_stream~, end_headers~, ..) => {
      let fields = self.fields(fragment) catch {
        err => [("undecodable", err.to_string())]
      }
      let shown = fields.map(field => shown_field(field.0, field.1)).join(", ")
      "HEADERS \{stream_id}\{flag(end_stream, " END_STREAM")}\{flag(end_headers, " END_HEADERS")} [\{shown}]"
    }
    Priority(stream_id~, ..) => "PRIORITY \{stream_id}"
    RstStream(stream_id~, error_code~) =>
      "RST_STREAM \{stream_id} \{error_name(error_code)}"
    Settings(params~, ack~) =>
      if ack {
        "SETTINGS ACK"
      } else {
        let shown = params.map(param => "\{setting_name(param.0)}=\{param.1}")
        "SETTINGS [\{shown.join(", ")}]"
      }
    PushPromise(stream_id~, promised_id~, ..) =>
      "PUSH_PROMISE \{stream_id} promising \{promised_id}"
    Ping(ack~, ..) => "PING\{flag(ack, " ACK")}"
    GoAway(last_stream_id~, error_code~, ..) =>
      "GOAWAY last=\{last_stream_id} \{error_name(error_code)}"
    WindowUpdate(stream_id~, increment~) =>
      "WINDOW_UPDATE \{stream_id} +\{increment}"
    Continuation(stream_id~, end_headers~, ..) =>
      "CONTINUATION \{stream_id}\{flag(end_headers, " END_HEADERS")}"
    Unknown(ftype~, stream_id~, ..) => "frame of type \{ftype} on \{stream_id}"
  }
}

///|
/// `text` when `set`, else nothing.
fn flag(set : Bool, text : String) -> String {
  if set {
    text
  } else {
    ""
  }
}

///|
/// The name RFC 9113, section 6.5.2, gives a setting.
fn setting_name(id : Int32) -> String {
  match id {
    0x1 => "HEADER_TABLE_SIZE"
    0x2 => "ENABLE_PUSH"
    0x3 => "MAX_CONCURRENT_STREAMS"
    0x4 => "INITIAL_WINDOW_SIZE"
    0x5 => "MAX_FRAME_SIZE"
    0x6 => "MAX_HEADER_LIST_SIZE"
    0x8 => "ENABLE_CONNECT_PROTOCOL"
    _ => "0x\{id.to_string(radix=16)}"
  }
}

///|
/// The response on one stream as a test shows it, on one line: the status,
/// the header fields, and how the stream ended.
fn H2Response::line(self : H2Response) -> String {
  let fields = self.headers.map(header => shown_field(header.0, header.1))
  "\{self.status} [\{fields.join(", ")}] \{self.body.length()} octets, \{self.ended}"
}

///|
/// Reads smock's SETTINGS, the first frame it sends on a connection,
/// acknowledges them, and shows them as `render_frame` does.
async fn RawH2::acknowledge_settings(self : RawH2) -> String {
  guard self.read_frame() is Some(Settings(ack=false, ..) as frame) else {
    fail("smock's SETTINGS did not come first")
  }
  self.send([Settings(params=[], ack=true)])
  self.render_frame(frame)
}

///|
/// The Journal's entries, one per line, as `<method> <target> <body>
/// <status>`.
async fn uploads_journaled(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object(
            {
              "method": String(meth),
              "target": String(target),
              "body": Object({ "data": String(body), .. }),
              ..
            }
          ),
          "status": status,
          ..
        }
      ) else {
      fail("an entry without a request: \{entry.stringify()}")
    }
    out.push("\{meth} \{target} \{body} \{status.stringify()}")
  }
  out.join("\n")
}

///|
/// The fields of a CONNECT to `authority`: `:method` and `:authority`
/// alone, with no `:scheme` and no `:path` (RFC 9113, section 8.5), then
/// `headers`.
fn connect_fields(
  authority : String,
  headers~ : Array[(String, String)] = [],
) -> Array[(String, String)] {
  [(":method", "CONNECT"), (":authority", authority), ..headers]
}

///|
/// A Journal entry as the tests of CONNECT show it: the method and target
/// of its request, its Host, its Mock and Stub, its status, and how many
/// octets of body its request had.
fn connect_entry(entry : Json) -> String {
  guard entry
    is Object(
      {
        "host": host,
        "mock": mock,
        "stub": stub,
        "status": status,
        "request": Object(
          {
            "method": String(meth),
            "target": target,
            "version": String(version),
            "body": Object({ "size": size, .. }),
            ..
          }
        ),
        ..
      }
    ) else {
    return entry.stringify()
  }
  "\{version} \{meth} \{target.stringify()} host=\{host.stringify()} mock=\{mock.stringify()} stub=\{stub.stringify()} status=\{status.stringify()} body=\{size.stringify()} octets"
}

///|
/// The Journal's entries as `connect_entry` shows them, one per line.
async fn connect_journal(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  entries.map(connect_entry).join("\n")
}

///|
/// `lines`, one per line, with a run of the same line shown once, followed
/// by ` x<n>` when it comes `n` times in a row.
fn runs(lines : Array[String]) -> String {
  let out = []
  let mut i = 0
  while i < lines.length() {
    let mut n = 1
    while i + n < lines.length() && lines[i + n] == lines[i] {
      n += 1
    }
    out.push(if n == 1 { lines[i] } else { "\{lines[i]} x\{n}" })
    i += n
  }
  out.join("\n")
}

///|
/// Reads frames until smock ends the connection, and shows them as `runs`
/// does, then how it ended: `a FIN`, or `an RST`.
async fn RawH2::runs_until_closed(self : RawH2) -> String {
  let frames = self.frames_until(@async.now(), _ => false)
  "\{runs(frames.shown)}\nthen \{frames.how}"
}

///|
/// The PING frame a test floods smock with.
let ping : @http2.Frame = Ping(
  payload=b"\x00\x00\x00\x00\x00\x00\x00\x07",
  ack=false,
)

///|
/// `frame`, `n` times.
fn times(frame : @http2.Frame, n : Int32) -> Array[@http2.Frame] {
  Array::make(n, frame)
}

///|
/// What a fresh connection gets for `GET /fast`, as a test shows it: to the
/// plain port, or with `tls` to the TLS port.
async fn Smock::fresh(self : Smock, tls~ : Bool = false) -> String {
  let client = if tls { self.h2() } else { self.h2c() }
  defer client.close()
  let response = client.request("GET", "/fast", authority="localhost")
  "then a fresh connection: \{response.status} \{@utf8.decode_lossy(response.body)}"
}

///|
/// The log lines of the connections a defence closed, as `log_entries`
/// shows them.
fn defence_entries(logs : Array[String]) -> String {
  log_entries(logs.filter(line => line.contains("closed by a defence")))
}

///|
/// Opens a connection, sends the frames `setup` makes, and reads smock's
/// answers until `ready` holds for one; then sends the frames `flood`
/// makes, in one write, and shows, after `label`, what smock sends until
/// it ends the connection, then what a fresh connection gets. The client's
/// SETTINGS is one frame that does no work, so a flood that comes to 100
/// more passes the bound with its last frame. With `tls`, both connections
/// go to the TLS port.
async fn Smock::flood(
  self : Smock,
  label : String,
  setup~ : (RawH2) -> Array[@http2.Frame] = _ => [],
  ready~ : (@http2.Frame) -> Bool = frame => frame is Settings(ack=true, ..),
  tls~ : Bool = false,
  flood : (RawH2) -> Array[@http2.Frame],
) -> String {
  let raw = self.raw_h2(tls~)
  defer raw.close()
  raw.send(setup(raw))
  let before = raw.frames_until(@async.now(), frame => {
    ready(frame) || is_goaway(frame)
  })
  raw.send(flood(raw))
  [
    "\{label}:",
    runs(before.shown),
    "flood:",
    raw.runs_until_closed(),
    self.fresh(tls~),
  ].join("\n")
}

///|
/// Reads frames from smock as `frames_until` does, until smock's PING, and
/// acknowledges it, as a client does.
async fn RawH2::frames_until_ping_acked(self : RawH2, since : Int64) -> Frames {
  let payload = Ref(b"")
  let frames = self.frames_until(since, frame => {
    guard frame is Ping(payload=p, ack=false) else { return false }
    payload.val = p
    true
  })
  self.send([Ping(payload=payload.val, ack=true)])
  frames
}

///|
/// Reads events until each stream of `due` has ended, been reset, or the
/// connection has closed, and shows, for each stream in the order of
/// `due`, what came on it, a line each: its HEADERS with their fields, each
/// DATA with its octets as text, as `data` shows them, and how it ended.
/// `due` gives, for each stream, when its HEADERS are due and then when
/// each DATA is, in milliseconds after `start`. A frame due later says
/// whether it came then (`arrival`). A frame due at once, at 0, says `at
/// once` when it came before every frame due later, on any stream of the
/// connection: smock sends a connection's frames in one order, so that
/// order, not the runner's speed, shows that it did not wait.
async fn H2Client::timeline(
  self : H2Client,
  start~ : Int64,
  due~ : Array[(Int32, Array[Int32])],
  data~ : (String) -> String = text => text.escape(),
) -> String {
  let seen : Map[Int32, Array[String]] = Map([])
  for stream in due {
    seen[stream.0] = []
  }
  let mut open = due.length()
  // Whether a frame due later than at once has come, on any stream.
  let later = Ref(false)
  let when = (stream : Int32, ms : Int64) => {
    let lines = seen.get(stream).unwrap()
    let times = due.filter(entry => entry.0 == stream)[0].1
    if lines.length() >= times.length() {
      later.val = true
      "at \{ms} ms, after the frames due"
    } else if times[lines.length()] > 0 {
      later.val = true
      arrival(ms, times[lines.length()])
    } else if later.val {
      "at \{ms} ms, after a frame due later"
    } else {
      "at once"
    }
  }
  while open > 0 {
    let event = self.read_event()
    let ms = @async.now() - start
    match event {
      Response(stream~, fields~) if seen.contains(stream) => {
        let shown = fields.map(field => {
          shown_field(
            @utf8.decode_lossy(field.name),
            @utf8.decode_lossy(field.value),
          )
        })
        let at = when(stream, ms)
        seen.get(stream).unwrap().push("HEADERS \{at}: \{shown.join(", ")}")
      }
      Data(stream~, data=octets) if seen.contains(stream) => {
        let at = when(stream, ms)
        seen
        .get(stream)
        .unwrap()
        .push("DATA \{at}: \{data(@utf8.decode_lossy(octets))}")
      }
      End(stream~) if seen.contains(stream) => {
        seen.get(stream).unwrap().push("end")
        open -= 1
      }
      Reset(stream~, code~, ..) if seen.contains(stream) => {
        seen.get(stream).unwrap().push("reset \{error_name(code)}")
        open -= 1
      }
      Closed => break
      _ => ()
    }
  }
  let out = []
  for stream in due {
    out.push("stream \{stream.0}:")
    for line in seen.get(stream.0).unwrap() {
      out.push("  \{line}")
    }
  }
  out.join("\n")
}

///|
/// The Journal's entries, each shown as its target, its Stub, its status
/// and whether its `durationMs` is below `below`, once there are `count`
/// of them, or as they are after `within` milliseconds.
async fn Smock::journal_durations(
  self : Smock,
  count : Int32,
  below~ : Int32,
  within~ : Int32,
) -> Array[String] {
  let start = @async.now()
  for ;; {
    let (_, journal) = self.journal()
    guard journal is Object({ "entries": Array(entries), .. }) else {
      fail("no entries: \{journal.stringify()}")
    }
    if entries.length() >= count || @async.now() - start >= within.to_int64() {
      return entries.map(entry => {
        guard entry
          is Object(
            {
              "request": Object({ "target": String(target), .. }),
              "stub": stub,
              "status": status,
              "durationMs": Number(duration, ..),
              ..
            }
          ) else {
          return entry.stringify()
        }
        let short = duration < below.to_double()
        "\{target}: stub \{stub.stringify()}, status \{status.stringify()}, durationMs below \{below}: \{short}"
      })
    }
    @async.sleep(20)
  }
}

///|
/// Mock `m` with Stubs for every Fault over HTTP/2: `/fast` at once,
/// `/reset`, `/close` and `/partial` (a body of ten octets) with their
/// connection Faults, and partial Faults on responses with no body to
/// halve, `/empty` (200 with no body) and `/no-content` (204), and on
/// Server-Sent Events, `/ticks` (four events, the third two seconds after
/// the second) and `/tick` (one event, after two seconds); `/later`
/// answers after a delay of 500 ms, and `/upload` any request at once.
/// After a delay, `/late-partial` (300 ms), `/late-ticks` (400 ms, three
/// events), `/late-reset` (500 ms) and `/late-close` (700 ms) take their
/// Faults; `/big-partial` has a partial Fault on the 150,000 octets of
/// `big_body`, from the body file `big.txt`.
let h2_faults : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
  #|      "response": { "status": 200, "body": "fast" } },
  #|    { "id": "reset", "mock": "m", "request": { "path": "/reset" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "connection": { "kind": "reset" } } },
  #|    { "id": "close", "mock": "m", "request": { "path": "/close" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "connection": { "kind": "close" } } },
  #|    { "id": "partial", "mock": "m", "request": { "path": "/partial" },
  #|      "response": { "status": 200, "headers": { "Content-Type": "text/plain" },
  #|        "body": "0123456789" },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "empty", "mock": "m", "request": { "path": "/empty" },
  #|      "response": { "status": 200 },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "no-content", "mock": "m", "request": { "path": "/no-content" },
  #|      "response": { "status": 204 },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "ticks", "mock": "m", "request": { "path": "/ticks" },
  #|      "response": { "status": 200, "events": [
  #|        { "data": "one" }, { "delay": 200, "data": "two" },
  #|        { "delay": 2000, "data": "three" }, { "data": "four" } ] },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "tick", "mock": "m", "request": { "path": "/tick" },
  #|      "response": { "status": 200, "events": [
  #|        { "delay": 2000, "data": "one" } ] },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "later", "mock": "m", "request": { "path": "/later" },
  #|      "response": { "status": 200, "body": "later" },
  #|      "fault": { "delay": { "fixed": 500 } } },
  #|    { "id": "upload", "mock": "m", "request": { "path": "/upload" },
  #|      "response": { "status": 201, "body": "stored" } },
  #|    { "id": "late-partial", "mock": "m", "request": { "path": "/late-partial" },
  #|      "response": { "status": 200, "body": "0123456789" },
  #|      "fault": { "delay": { "fixed": 300 },
  #|        "connection": { "kind": "partial" } } },
  #|    { "id": "late-ticks", "mock": "m", "request": { "path": "/late-ticks" },
  #|      "response": { "status": 200, "events": [
  #|        { "data": "one" }, { "data": "two" }, { "data": "three" } ] },
  #|      "fault": { "delay": { "fixed": 400 },
  #|        "connection": { "kind": "partial" } } },
  #|    { "id": "late-reset", "mock": "m", "request": { "path": "/late-reset" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "delay": { "fixed": 500 },
  #|        "connection": { "kind": "reset" } } },
  #|    { "id": "late-close", "mock": "m", "request": { "path": "/late-close" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "delay": { "fixed": 700 },
  #|        "connection": { "kind": "close" } } },
  #|    { "id": "big-partial", "mock": "m", "request": { "path": "/big-partial" },
  #|      "response": { "status": 200, "bodyFile": "big.txt" },
  #|      "fault": { "connection": { "kind": "partial" } } } ] }

///|
/// The Definition files of the Fault tests: `h2_faults` and its body file.
fn fault_definitions() -> Array[(String, String)] {
  [("m.json", h2_faults), ("files/big.txt", big_body)]
}

///|
/// A body of `lines` lines, each a number of seven digits and a newline,
/// counting from 0, so that a part sent twice, lost or out of order shows.
fn numbered(lines : Int32) -> String {
  let out = StringBuilder()
  for i in 0..<lines {
    let digits = i.to_string()
    out.write_string("0".repeat(7 - digits.length()))
    out.write_string(digits)
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// The body of `GET /big`: 150,000 octets, more than both of the windows a
/// client starts with (65,535 octets each).
let big_body : String = numbered(18_750)

///|
/// The body of `GET /medium`: 65,544 octets, nine more than the connection
/// window a client starts with.
let medium_body : String = numbered(8193)

///|
/// Mock `m`, for `localhost`, with Stubs that answer `GET /big` with
/// `big_body`, `GET /medium` with `medium_body`, `GET /item` with a short
/// body, and `GET /slow-big` with `big_body` after a delay of 300 ms.
fn flow_definitions() -> Array[(String, String)] {
  [
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "big", "mock": "m", "request": { "path": "/big" },
        #|      "response": { "status": 200, "bodyFile": "big.txt" } },
        #|    { "id": "medium", "mock": "m", "request": { "path": "/medium" },
        #|      "response": { "status": 200, "bodyFile": "medium.txt" } },
        #|    { "id": "item", "mock": "m", "request": { "path": "/item" },
        #|      "response": { "status": 200, "body": "hello" } },
        #|    { "id": "slow-big", "mock": "m", "request": { "path": "/slow-big" },
        #|      "response": { "status": 200, "bodyFile": "big.txt" },
        #|      "fault": { "delay": { "fixed": 300 } } } ] }
      ),
    ),
    ("files/big.txt", big_body),
    ("files/medium.txt", medium_body),
  ]
}

///|
/// Reads frames until `stop` holds for one, or smock ends the connection,
/// and shows each as `render_frame` does, one per line, except that DATA
/// frames in a row on one stream show as one line: how many there are,
/// their octets, and whether the last ends the stream.
async fn RawH2::runs_until(
  self : RawH2,
  stop : (@http2.Frame) -> Bool,
) -> String {
  let out = []
  // The stream, frame count and octets of the DATA frames in a row so far.
  let mut run = (0, 0, 0)
  let flush = (end : Bool) => {
    let (stream, frames, octets) = run
    if frames > 0 {
      let ended = if end { " END_STREAM" } else { "" }
      out.push("DATA \{stream}\{ended}: \{frames} frames, \{octets} octets")
    }
    run = (0, 0, 0)
  }
  for ;; {
    guard self.read_frame() is Some(frame) else {
      flush(false)
      out.push("closed")
      break
    }
    match frame {
      Data(stream_id~, data~, end_stream~, ..) => {
        if run.0 != stream_id {
          flush(false)
        }
        run = (stream_id, run.1 + 1, run.2 + data.length())
        if end_stream {
          flush(true)
        }
      }
      _ => {
        flush(false)
        out.push(self.render_frame(frame))
      }
    }
    if stop(frame) {
      flush(false)
      break
    }
  }
  out.join("\n")
}

///|
/// Whether `frame` ends `stream`: DATA or HEADERS with END_STREAM, or
/// RST_STREAM.
fn ends_stream(frame : @http2.Frame, stream : Int32) -> Bool {
  match frame {
    Data(stream_id~, end_stream=true, ..)
    | Headers(stream_id~, end_stream=true, ..)
    | RstStream(stream_id~, ..) => stream_id == stream
    _ => false
  }
}

///|
/// A PING from the client, whose acknowledgement shows where smock's
/// answers to the frames before it end.
let fence : @http2.Frame = Ping(
  payload=b"\x00\x00\x00\x00\x00\x00\x00\x01",
  ack=false,
)

///|
/// A predicate on frames that holds once `octets` of DATA on `stream` have
/// come, counting from when it is made.
fn data_seen(stream : Int32, octets : Int32) -> (@http2.Frame) -> Bool {
  let mut seen = 0
  frame => {
    if frame is Data(stream_id~, data~, ..) && stream_id == stream {
      seen += data.length()
    }
    seen >= octets
  }
}

///|
/// The size of the header list `fields` as RFC 7541, section 4.1, counts
/// it: each field's name and value, in octets, plus 32.
fn list_size(fields : Array[(String, String)]) -> Int32 {
  let mut size = 0
  for field in fields {
    size += @utf8.encode(field.0).length() + @utf8.encode(field.1).length() + 32
  }
  size
}

///|
/// `fields`, then an `x-pad` field whose value of `a`s makes the list
/// `size` octets as RFC 7541, section 4.1, counts it.
fn padded(
  fields : Array[(String, String)],
  size : Int32,
) -> Array[(String, String)] {
  let pad = size - list_size(fields) - "x-pad".length() - 32
  [..fields, ("x-pad", String::make(pad, 'a'))]
}

///|
/// The Journal's entries, one per line, as `<method> <target>`.
async fn journaled(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object(
            { "method": String(meth), "target": String(target), .. }
          ),
          ..
        }
      ) else {
      fail("an entry without a request: \{entry.stringify()}")
    }
    out.push("\{meth} \{target}")
  }
  out.join("\n")
}

///|
/// The body of `/large`: 131,072 octets (128 KiB).
let large_body : String = numbered(16_384)

///|
/// The body of `/larger`: 524,288 octets (512 KiB).
let larger_body : String = numbered(65_536)

///|
/// Mock `m`, for `localhost`, with Stubs that answer `/large` with
/// `large_body`, `/small` with a short body, and `/late` with
/// `larger_body` after a delay of 100 ms.
fn output_definitions() -> Array[(String, String)] {
  [
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "large", "mock": "m", "request": { "path": "/large" },
        #|      "response": { "status": 200, "bodyFile": "large.txt" } },
        #|    { "id": "small", "mock": "m", "request": { "path": "/small" },
        #|      "response": { "status": 200, "body": "hello" } },
        #|    { "id": "late", "mock": "m", "request": { "path": "/late" },
        #|      "response": { "status": 200, "bodyFile": "larger.txt" },
        #|      "fault": { "delay": { "fixed": 100 } } } ] }
      ),
    ),
    ("files/large.txt", large_body),
    ("files/larger.txt", larger_body),
  ]
}

///|
/// `shown`, a frame as `render_frame` shows it, with the stream ID it
/// names as `n`, so that the like frames of many streams show alike.
fn any_stream(shown : String) -> String {
  let words = shown.split(" ").map(word => word.to_owned()).collect()
  if words.length() > 1 &&
    words[1] != "" &&
    words[1].iter().all(c => c >= '0' && c <= '9') {
    words[1] = "n"
  }
  words.join(" ")
}

///|
/// `lines`, each with its stream ID as `n` (`any_stream`), and each such
/// line once, in the order it first came, followed by ` x<n>` when it came
/// `n` times in all.
fn tally(lines : Array[String]) -> String {
  let counts : Map[String, Int32] = Map([])
  for line in lines {
    let key = any_stream(line)
    counts[key] = counts.get(key).unwrap_or(0) + 1
  }
  let out = []
  for line, n in counts {
    out.push(if n == 1 { line } else { "\{line} x\{n}" })
  }
  out.join("\n")
}

///|
/// Reads frames until smock ends the connection, and shows them as `tally`
/// does, then how it ended: `a FIN`, or `an RST`.
async fn RawH2::tally_until_closed(self : RawH2) -> String {
  let frames = self.frames_until(@async.now(), _ => false)
  "\{tally(frames.shown)}\nthen \{frames.how}"
}

///|
/// Reads frames until the acknowledgement of a PING, and shows each frame
/// before it as `render_frame` does, one per line. smock answers frames in
/// order, so the frames of the streams the client ended before its PING
/// come first.
async fn RawH2::frames_until_ping_ack(self : RawH2) -> String {
  let out = []
  while self.read_frame() is Some(frame) {
    if frame is Ping(ack=true, ..) {
      return out.join("\n")
    }
    out.push(self.render_frame(frame))
  }
  out.push("closed")
  out.join("\n")
}

///|
/// The status of an HTTP/1.1 response and its body, read from `conn`.
async fn http1_status_and_body(conn : Conn) -> (Int32, Bytes) {
  guard read_framed(conn) is Some((head, body)) else {
    fail("the connection closed without a response")
  }
  let status_line = head[:head.find("\r\n").unwrap_or(head.length())]
  (@string.parse_int(status_line.split(" ").nth(1).unwrap()), body)
}

///|
/// The fields of a request with the method `meth` for `path` to
/// `authority`.
fn request_fields(
  meth : String,
  path : String,
  authority : String,
) -> Array[(String, String)] {
  [
    (":method", meth),
    (":scheme", "http"),
    (":path", path),
    (":authority", authority),
  ]
}

///|
/// A HEADERS frame on `stream` that carries all of `block`, and ends the
/// stream unless `end_stream` is false.
fn headers_frame(
  stream : Int32,
  block : Bytes,
  end_stream~ : Bool = true,
) -> @http2.Frame {
  Headers(
    stream_id=stream,
    fragment=block,
    end_stream~,
    end_headers=true,
    priority=None,
    padding=0,
  )
}

///|
/// Mock `m` with Stubs that answer `GET /slow` after a fixed delay of
/// 1000 ms, and `GET /fast` at once.
let delays : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "slow", "mock": "m", "request": { "path": "/slow" },
  #|      "response": { "status": 200, "body": "slow" },
  #|      "fault": { "delay": { "fixed": 1000 } } },
  #|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
  #|      "response": { "status": 200, "body": "fast" } } ] }

///|
/// The HEADERS frame of a GET of `path` on `stream`, which ends the stream.
fn RawH2::get(self : RawH2, stream : Int32, path : String) -> @http2.Frame {
  Headers(
    stream_id=stream,
    fragment=self.block([
      (":method", "GET"),
      (":scheme", "http"),
      (":path", path),
      (":authority", "localhost"),
    ]),
    end_stream=true,
    end_headers=true,
    priority=None,
    padding=0,
  )
}

///|
/// Reads frames until one ends `stream`, and shows each as `render_frame`
/// does, one per line.
async fn RawH2::frames_until_end_of(self : RawH2, stream : Int32) -> String {
  let out = []
  for ;; {
    guard self.read_frame() is Some(frame) else {
      out.push("closed")
      break
    }
    out.push(self.render_frame(frame))
    match frame {
      Data(stream_id~, end_stream=true, ..)
      | Headers(stream_id~, end_stream=true, ..)
      | RstStream(stream_id~, ..) if stream_id == stream => break
      _ => ()
    }
  }
  out.join("\n")
}

///|
/// The Journal's entries, each shown as its target, its Stub and its
/// status, once there are `count` of them, or as they are after `within`
/// milliseconds: the first 100, or the first `limit`.
async fn Smock::journal_once(
  self : Smock,
  count : Int32,
  within~ : Int32,
  limit~ : Int32 = 100,
) -> Array[String] {
  let start = @async.now()
  for ;; {
    let (_, journal) = self.journal(query="{\"limit\":\{limit}}")
    guard journal is Object({ "entries": Array(entries), .. }) else {
      fail("no entries: \{journal.stringify()}")
    }
    if entries.length() >= count || @async.now() - start >= within.to_int64() {
      return entries.map(entry => {
        guard entry
          is Object(
            {
              "request": Object({ "target": String(target), .. }),
              "stub": stub,
              "status": status,
              ..
            }
          ) else {
          return entry.stringify()
        }
        "\{target}: stub \{stub.stringify()}, status \{status.stringify()}"
      })
    }
    @async.sleep(20)
  }
}

///|
/// Mock `m` with a Stub that answers `GET /big` with a body of 65,536
/// octets after a fixed delay of 300 ms.
fn big_delayed() -> String {
  let body = StringBuilder()
  for _ in 0..<65536 {
    body.write_char('x')
  }
  (
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [
    #|    { "id": "big", "mock": "m", "request": { "path": "/big" },
    #|      "fault": { "delay": { "fixed": 300 } },
  ) +
  "\"response\": { \"status\": 200, \"body\": \"\{body.to_string()}\" } } ] }"
}

///|
/// A Mock that answers every Host, with a Stub that takes uploads.
let uploads : String =
  #|{ "mocks": [{ "name": "files" }],
  #|  "stubs": [{ "id": "upload", "mock": "files",
  #|    "request": { "method": "POST", "path": "/upload" },
  #|    "response": { "status": 201, "body": "stored" } }] }

///|
/// A response in one line: its status and its body, or that none came, and
/// how its stream ended.
fn H2Response::brief(self : H2Response) -> String {
  let response = if self.status == 0 {
    "no response"
  } else {
    "\{self.status} \{@utf8.decode_lossy(self.body)}"
  }
  "\{response} (\{self.ended})"
}

///|
/// The log lines of a smock process started with `--port 0` and no
/// certificate, that wrote nothing between starting and draining when it
/// was stopped: timeouts are not logged.
let startup_only_h2c : String =
  #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
  #|{"level":"info","msg":"random seed","seed":"*"}
  #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
  #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
  #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*","protocols":["http/1.1"]}
  #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"*","names":["localhost","127.0.0.1","::1"]}
  #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*","protocols":["http/1.1","h2c"]}
  #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","protocols":["h2","http/1.1"]}
  #|{"level":"info","msg":"drain started","timeoutMs":20000}
  #|{"level":"info","msg":"drain ended","connectionsCut":0}

///|
/// The frames smock sent, as `RawH2::frames_until` read them.
struct Frames {
  /// Each frame, as `render_frame` shows it.
  shown : Array[String]
  /// How they ended: `open` when a frame met the condition, else how
  /// smock ended the connection, `a FIN` for a clean end of stream or `an
  /// RST` for a reset.
  how : String
  /// When the last frame came or the connection ended, in milliseconds
  /// after the time the caller gave.
  end_ms : Int64
}

///|
/// Reads frames from smock until one meets `stop`, or smock ends the
/// connection, timing the last from `since`, and, over TCP, tells a FIN
/// from a reset.
async fn RawH2::frames_until(
  self : RawH2,
  since : Int64,
  stop : (@http2.Frame) -> Bool,
) -> Frames {
  let shown = []
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let (frame, used) = @http2.decode(self.received) catch {
        Incomplete => {
          let n = self.wire.read(self.buf) catch {
            @os_error.OSError(_, ..) as err if is_reset(err) => break "an RST"
            err => break "an error: \{err}"
          }
          guard n > 0 else { break "a FIN" }
          self.received = self.received +
            self.buf.unsafe_reinterpret_as_bytes()[:n].to_owned()
          continue
        }
        err => fail("smock sent a frame that does not decode: \{err}")
      }
      self.received = self.received[used:].to_owned()
      shown.push(self.render_frame(frame))
      if stop(frame) {
        break "open"
      }
    }
  })
  guard result is Some(how) else { fail("no frame and no end in time") }
  { shown, how, end_ms: @async.now() - since, }
}

///|
/// Whether `frame` is a GOAWAY.
fn is_goaway(frame : @http2.Frame) -> Bool {
  frame is GoAway(..)
}
