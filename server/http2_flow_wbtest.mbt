// HTTP/2 flow control on a connection that smock serves in process, over
// two in-memory pipes with no buffer between smock and the client: each
// write of smock's waits until the client reads it. So a test can hold a
// write of smock's while smock reads the client's next frames, which a
// socket allows only once its buffers are full, at a point that a test
// cannot choose (#391).

///|
/// smock's end of a connection served in process: it reads what the client
/// sends from `input`, and writes to `output`, which the client reads.
priv struct PipeEnd {
  input : @io.PipeRead
  output : @io.PipeWrite
  /// How many reads smock has begun.
  mut reads : Int32
  /// How many writes smock has begun.
  mut writes : Int32
  /// Signalled when smock begins a read or a write.
  changed : @async.CondVar
}

///|
/// smock reads what the client sends through `input`, as it would read a
/// socket.
impl @io.Reader for PipeEnd with fn _get_internal_buffer(self) {
  @io.Reader::_get_internal_buffer(self.input)
}

///|
/// A read of smock's, counted as it begins: it waits until the client
/// sends.
impl @io.Reader for PipeEnd with fn _direct_read(self, buf, offset~, max_len~) {
  self.reads += 1
  self.changed.broadcast()
  @io.Reader::_direct_read(self.input, buf, offset~, max_len~)
}

///|
/// A write of smock's, counted as it begins: it waits until the client
/// reads, and returns what the client read of it.
impl @io.Writer for PipeEnd with fn write_once(self, data, offset~, len~) {
  self.writes += 1
  self.changed.broadcast()
  self.output.write_once(data, offset~, len~)
}

///|
/// A read of the pipe writes nothing, as a read of plain TCP does not.
impl ReadOutput for PipeEnd with fn hold_read_output(_) {

}

///|
/// A read of the pipe never leaves output.
impl ReadOutput for PipeEnd with fn has_read_output(_) {
  false
}

///|
/// A read of the pipe leaves no output to send.
impl ReadOutput for PipeEnd with fn write_read_output(_, _) {

}

///|
/// How long a test waits for smock to begin a read or a write before it
/// fails, in milliseconds: long enough for a loaded machine, so that it
/// fails only when smock never does.
let patience_ms : Int32 = 10_000

///|
/// Waits until smock has begun more than `count` reads: it has handled what
/// the client sent before them, and waits for more.
async fn PipeEnd::reads_past(self : PipeEnd, count : Int32) -> Unit {
  let waited = @async.with_timeout_opt(patience_ms, () => {
    while self.reads <= count {
      self.changed.wait()
    }
  })
  guard waited is Some(_) else { fail("smock read no more") }
}

///|
/// Waits until smock has begun more than `count` writes.
async fn PipeEnd::writes_past(self : PipeEnd, count : Int32) -> Unit {
  let waited = @async.with_timeout_opt(patience_ms, () => {
    while self.writes <= count {
      self.changed.wait()
    }
  })
  guard waited is Some(_) else { fail("smock wrote no more") }
}

///|
/// The client's end of a connection served in process. What it sends goes
/// out from a task of its own, so that the client, as over a socket, can
/// send while smock writes what it has not read yet.
priv struct PipeClient {
  /// What the client sends, which smock reads.
  to_smock : @io.PipeWrite
  /// What smock writes, which the client reads.
  from_smock : @io.PipeRead
  /// smock's end.
  smock : PipeEnd
  /// The octets read from smock and not yet split into frames.
  mut received : Bytes
  /// What the client has sent and smock has not all read yet, oldest
  /// first.
  unsent : Array[Bytes]
  /// Signalled when the client sends.
  sent : @async.CondVar
}

///|
/// Runs `steps` with the client's end of an HTTP/2 connection that `ports`
/// serve in process, which has sent the connection preface, then ends the
/// connection.
async fn with_pipe_client(
  ports : MockPorts,
  steps : async (PipeClient) -> Unit,
) -> Unit {
  let (input, to_smock) = @io.pipe()
  let (from_smock, output) = @io.pipe()
  let smock : PipeEnd = {
    input,
    output,
    reads: 0,
    writes: 0,
    changed: @async.CondVar::Cond(),
  }
  let client = {
    to_smock,
    from_smock,
    smock,
    received: b"",
    unsent: [@http2.preface],
    sent: @async.CondVar::Cond(),
  }
  let connection : Connection = { idle: true, drain: None, task: None, }
  // Once the steps are over, the client closes its end, and a write of
  // smock's still going on fails, as on a socket that the client closed.
  let mut over = false
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      let _ = ports.serve_http2(smock, connection, b"") catch {
        error => if over { false } else { raise error }
      }
    })
    group.spawn_bg(no_wait=true, () => {
      for ;; {
        while client.unsent.is_empty() {
          client.sent.wait()
        }
        client.to_smock.write(client.unsent.remove(0))
      }
    })
    steps(client)
    over = true
    client.to_smock.close()
    client.from_smock.close()
  })
}

///|
/// Sends `frames`, in one write, from the client's task that sends: smock
/// reads them once it reads again.
fn PipeClient::send(self : PipeClient, frames : Array[@http2.Frame]) -> Unit {
  let out = @buffer.Buffer()
  for frame in frames {
    out.write_bytes(frame.encode())
  }
  self.unsent.push(out.to_bytes())
  self.sent.signal()
}

///|
/// Reads at most `max` octets of what smock writes: what it has begun to
/// write, once it begins.
async fn PipeClient::read_some(self : PipeClient, max : Int32) -> Unit {
  let buf = FixedArray::make(max, b'\x00')
  guard @async.with_timeout_opt(patience_ms, () => self.from_smock.read(buf))
    is Some(n) else {
    fail("smock wrote nothing")
  }
  guard n > 0 else { fail("smock ended the connection") }
  self.received = self.received +
    buf.unsafe_reinterpret_as_bytes()[:n].to_owned()
}

///|
/// The next frame from smock, read `max` octets at a time, and after each
/// read but the last, a pause of `pause_ms`.
async fn PipeClient::next_frame(
  self : PipeClient,
  max~ : Int32 = 16_384,
  pause_ms~ : Int32 = 0,
) -> @http2.Frame {
  for ;; {
    let (frame, used) = @http2.decode(self.received) catch {
      Incomplete => {
        if pause_ms > 0 && self.received.length() > 0 {
          @async.sleep(pause_ms)
        }
        self.read_some(max)
        continue
      }
      err => fail("smock sent a frame that does not decode: \{err}")
    }
    self.received = self.received[used:].to_owned()
    return frame
  }
}

///|
/// Reads frames from smock until `stop` holds for one, and shows each, one
/// a line, except that DATA frames in a row on one stream show as one line:
/// how many there are, their octets, and whether the last ends the stream.
/// With `max` and `pause_ms`, it reads as `next_frame` does.
async fn PipeClient::runs_until(
  self : PipeClient,
  stop : (@http2.Frame) -> Bool,
  max~ : Int32 = 16_384,
  pause_ms~ : Int32 = 0,
) -> String {
  let out = []
  // The stream, frame count and octets of the DATA frames in a row so far,
  // and whether the last ended the stream.
  let mut run = (0, 0, 0, false)
  let flush = () => {
    let (stream, frames, octets, ended) = run
    if frames > 0 {
      let end = if ended { " END_STREAM" } else { "" }
      out.push("DATA \{stream}\{end}: \{frames} frames, \{octets} octets")
    }
    run = (0, 0, 0, false)
  }
  for ;; {
    let frame = self.next_frame(max~, pause_ms~)
    match frame {
      Data(stream_id~, data~, end_stream~, ..) => {
        if run.0 != stream_id {
          flush()
        }
        run = (stream_id, run.1 + 1, run.2 + data.length(), end_stream)
      }
      _ => {
        flush()
        out.push(shown_frame(frame))
      }
    }
    if stop(frame) {
      flush()
      return out.join("\n")
    }
  }
}

///|
/// A frame from smock other than DATA, as a test shows it: its type, its
/// stream and what it carries that a test checks.
fn shown_frame(frame : @http2.Frame) -> String {
  match frame {
    Headers(stream_id~, end_stream~, ..) => {
      let end = if end_stream { " END_STREAM" } else { "" }
      "HEADERS \{stream_id}\{end}"
    }
    RstStream(stream_id~, error_code~) =>
      if error_code == @http2.error_cancel {
        "RST_STREAM \{stream_id} CANCEL"
      } else {
        "RST_STREAM \{stream_id} \{error_code}"
      }
    Settings(ack~, ..) => if ack { "SETTINGS ACK" } else { "SETTINGS" }
    Ping(ack~, ..) => if ack { "PING ACK" } else { "PING" }
    GoAway(error_code~, ..) => "GOAWAY \{error_code}"
    WindowUpdate(stream_id~, increment~) =>
      "WINDOW_UPDATE \{stream_id} +\{increment}"
    _ => "another frame"
  }
}

///|
/// A predicate on frames that holds once `octets` of DATA have come, on
/// any stream, counting from when it is made.
fn data_total(octets : Int32) -> (@http2.Frame) -> Bool {
  let mut seen = 0
  frame => {
    if frame is Data(data~, ..) {
      seen += data.length()
    }
    seen >= octets
  }
}

///|
/// HEADERS for a GET of `path` on `stream`, which end the stream. Each field
/// is an HPACK literal that is not indexed, with a new name and no Huffman
/// code (RFC 7541, section 6.2.2), so that no encoder is needed.
fn get_request(stream : Int32, path : String) -> @http2.Frame {
  let block = @buffer.Buffer()
  for
    field in [
      (":method", "GET"),
      (":scheme", "http"),
      (":path", path),
      (":authority", "localhost"),
    ] {
    block.write_byte(b'\x00')
    for text in [field.0, field.1] {
      let octets = @utf8.encode(text)
      block.write_byte(octets.length().to_byte())
      block.write_bytes(octets)
    }
  }
  Headers(
    stream_id=stream,
    fragment=block.to_bytes(),
    end_stream=true,
    end_headers=true,
    priority=None,
    padding=0,
  )
}

///|
/// The Mock ports of a definition set with two Stubs, with the settings
/// that `args` gives `smock serve`: `GET /big`, whose body is 150,000
/// octets, and `GET /item`, whose body is the 5 octets "hello", as in
/// e2e's tests of flow control.
fn flow_ports(args : Array[String]) -> MockPorts raise {
  let settings = @settings.ServeSettings::from_matches(
    @settings.serve_command().parse(argv=args, env={}),
  )
  let definitions =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [
    #|    { "id": "big", "mock": "m", "request": { "path": "/big" },
    #|      "response": { "status": 200, "bodyFile": "big.txt" } },
    #|    { "id": "item", "mock": "m", "request": { "path": "/item" },
    #|      "response": { "status": 200, "body": "hello" } } ] }
  guard @definitions.load({
      files: [("m.json", @utf8.encode(definitions))],
      body_files: [("big.txt", Bytes::make(150_000, b'x'))],
    })
    is Ok(snapshot) else {
    abort("the flow definitions are valid")
  }
  let engine = @engine.Engine(snapshot)
  let lifecycle = Lifecycle::new()
  lifecycle.started(engine)
  {
    engine,
    rand: @prng.Generator(1),
    settings,
    sessions: {
      header: settings.session_header,
      member_name: settings.session_member,
    },
    dates: @http1.DateCache(),
    traffic: Traffic::register(@metrics.Registry()),
    lifecycle,
    logger: @log.Logger(write_line=_ => (), now=() => 0L),
    mockoon: None,
  }
}

///|
async test "a stream that has sent what the connection window gave it waits again from then, before its DATA has gone out, so a response queued while that DATA goes out waits behind it (#381, #391)" {
  // docs/http2.md, Streams that wait: "a stream that has sent what it was
  // given waits behind the others. A stream begins to wait as soon as the
  // windows hold back part of its body or of an event: when smock queues
  // what they allow, and more is left, before that has gone out. So ...
  // one queued while that stream's DATA goes out waits behind it."
  with_pipe_client(flow_ports([]), client => {
    let out = []
    // Wide stream windows, so that only the connection window of 65,535
    // octets holds the body back: stream 1 takes all of it and waits.
    client.send([
      Settings(
        params=[(@http2.settings_initial_window_size, 1_000_000)],
        ack=false,
      ),
      get_request(1, "/big"),
    ])
    out.push(client.runs_until(data_total(65_535)))
    // The 500 octets go to stream 1, whose task begins to write them; the
    // client reads none of them yet, so the write goes on while stream 3's
    // response is queued with no room for its body.
    out.push(
      "--- the connection window widened by 500; stream 3 opened while stream 1's DATA goes out",
    )
    let writes = client.smock.writes
    client.send([WindowUpdate(stream_id=0, increment=500)])
    client.smock.writes_past(writes)
    let reads = client.smock.reads
    client.send([get_request(3, "/item")])
    client.smock.reads_past(reads)
    out.push(client.runs_until(frame => frame is Headers(stream_id=3, ..)))
    // Stream 1 began to wait again as it queued its 500 octets, before
    // stream 3's response was queued: the next 5 octets go to stream 1.
    out.push("--- the connection window widened by 5")
    client.send([WindowUpdate(stream_id=0, increment=5)])
    out.push(client.runs_until(data_total(5)))
    inspect(
      out.join("\n"),
      content=(
        #|SETTINGS
        #|SETTINGS ACK
        #|HEADERS 1
        #|DATA 1: 4 frames, 65535 octets
        #|--- the connection window widened by 500; stream 3 opened while stream 1's DATA goes out
        #|DATA 1: 1 frames, 500 octets
        #|HEADERS 3
        #|--- the connection window widened by 5
        #|DATA 1: 1 frames, 5 octets
      ),
    )
  })
}

///|
async test "a stream's write timeout for its own window runs from once what it sent before has gone out: a client that reads that DATA slowly, for longer than the write timeout, then widens the window, gets the rest (#391)" {
  // #391: the write timeout of a wait for window "starts as on main, once
  // the stream's DATA is written". docs/http2.md, Timeouts: "For this
  // timeout, a body waits once what smock queued before it has gone out.
  // A stream that waits for window while its last DATA is still being
  // written ... has the write timeout of that write until then, so a
  // client that reads that DATA slowly but steadily, and widens the window
  // once it has read it, is not cut for it." The test widens the window
  // 200 ms after it has read the DATA, well within the write timeout of
  // 1000 ms, and reads the DATA for about 1.7 s, well past it.
  with_pipe_client(flow_ports(["--write-timeout-ms", "1000"]), client => {
    let out = []
    // Stream windows of 500 octets, with the connection window open: stream
    // 1's body waits for its own window.
    client.send([
      Settings(params=[(@http2.settings_initial_window_size, 500)], ack=false),
      get_request(1, "/big"),
    ])
    out.push(client.runs_until(data_total(500)))
    // The task of stream 1 begins to write the next 500 octets, which the
    // client does not read yet, and a PING meanwhile has smock's reader look
    // at the waits for window, as it does before each read.
    out.push(
      "--- stream 1's window widened by 500, and a PING while its DATA goes out",
    )
    let writes = client.smock.writes
    client.send([WindowUpdate(stream_id=1, increment=500)])
    client.smock.writes_past(writes)
    let reads = client.smock.reads
    client.send([Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false)])
    client.smock.reads_past(reads)
    // The client reads that DATA and the PING's acknowledgement 30 octets
    // every 100 ms: about 1.7 s, past the write timeout, while the write
    // goes on at each read.
    out.push(
      client.runs_until(
        frame => frame is Ping(ack=true, ..),
        max=30,
        pause_ms=100,
      ),
    )
    // Then it widens the window 200 ms after it has read them: within the
    // write timeout of the wait, from when the DATA has gone out.
    @async.sleep(200)
    out.push("--- stream 1's window widened by 149000, 200 ms later")
    client.send([WindowUpdate(stream_id=1, increment=149_000)])
    out.push(
      client.runs_until(frame => {
        frame is (Data(stream_id=1, ..) | RstStream(stream_id=1, ..))
      }),
    )
    // docs/http2.md, The output bound: "at most 16 KiB at a time, its DATA
    // frame's header included", so 16,384 - 9 octets.
    inspect(
      out.join("\n"),
      content=(
        #|SETTINGS
        #|SETTINGS ACK
        #|HEADERS 1
        #|DATA 1: 1 frames, 500 octets
        #|--- stream 1's window widened by 500, and a PING while its DATA goes out
        #|DATA 1: 1 frames, 500 octets
        #|PING ACK
        #|--- stream 1's window widened by 149000, 200 ms later
        #|DATA 1: 1 frames, 16375 octets
      ),
    )
  })
}
