// The Seam 2 harness: it runs the smock binary as a black box. Each test
// gets its own temporary definitions directory and its own ports (smock
// binds port 0 and logs the port it got), so tests run in parallel. They
// share one event loop, so a test computes for no more than about 20 ms
// between awaits: see "Build and test" in CONTRIBUTING.md. It also holds
// what several test files share and no other harness file is for: the
// Definition files they serve, the requests they send, and what they read
// back from responses, the Journal, the metrics, the logs and the status.

///|
/// The binary under test: the native debug build of `cmd/smock`. Tests run
/// with the module root as their working directory.
let binary : String = "_build/native/debug/build/smock/smock/cmd/smock/smock.exe"

///|
/// Builds the binary once per test process, so the tests always run the
/// code they are built from.
let build : @async.Lazy[Unit] = @async.Lazy(() => {
  let (status, output) = @process.collect_output_merged("moon", [
    "build", "--target", "native", "cmd/smock",
  ])
  if status != 0 {
    fail("moon build failed:\n\{output.text()}")
  }
})

///|
/// How long a test waits for smock to start listening or to exit.
let patience_ms : Int32 = 20_000

///|
/// Creates a temporary definitions directory holding `files`, given as
/// (relative path, text) pairs, runs `f` with its path and removes it.
async fn with_definitions(
  files : Array[(String, String)],
  f : async (String) -> Unit,
) -> Unit {
  let dir = @fs.tmpdir(prefix="smock-e2e-")
  defer @fs.rmdir(dir, recursive=true)
  for file in files {
    let (path, text) = file
    write(dir, path, text)
  }
  f(dir)
}

///|
/// The most UTF-16 code units of a text that `write` encodes at once.
let write_piece : Int32 = 1024 * 1024

///|
/// Writes `text` to `dir/path`, creating the directories on the way, as
/// `@fs.write_file` does. A text longer than `write_piece` is encoded and
/// written a piece at a time: encoding a 16 MiB body file in one go took
/// 50 to 150 ms, in which no other test of the package ran.
async fn write(dir : String, path : String, text : String) -> Unit {
  let parts = path.split("/").collect()
  let mut parent = dir
  for part in parts[:parts.length() - 1] {
    parent = "\{parent}/\{part}"
    @fs.mkdir(parent, allow_exist=true)
  }
  let file = @fs.open(
    "\{dir}/\{path}",
    mode=WriteOnly,
    sync=Data,
    create_mode=CreateOrTruncate,
  )
  defer file.close()
  let mut rest = text[:]
  while rest.length() > 0 {
    // A view never ends between the two halves of a surrogate pair.
    let piece = rest[:write_piece]
    file.write(@utf8.encode(piece))
    rest = rest[piece.length():]
  }
}

///|
/// How long a test waits for a reload after changing a file: a ceiling on
/// the wait, not how soon a reload must come, which is the 1 s poll
/// interval, the 250 ms quiet period and the time to read, validate and
/// hash every file. It leaves room for a machine busy with the tests that
/// run beside it.
let reload_patience_ms : Int32 = 5000

///|
/// Calls `f` every 20 ms until it gives a value, at most `within`
/// milliseconds, and returns that value, or `None` when the time runs out.
async fn[T] wait_for(within : Int32, f : async () -> T?) -> T? {
  @async.with_timeout_opt(within, () => {
    for ;; {
      if f() is Some(value) {
        break value
      }
      @async.sleep(20)
    }
  })
}

///|
/// Sleeps for part of a second: as many milliseconds as the clock has
/// past the second. smock polls every second from when it started, so a
/// change made after it comes at another point between two polls from run
/// to run, not always at the same one.
async fn sleep_part_of_a_second() -> Unit {
  @async.sleep((@async.now() % 1000L).to_int())
}

///|
/// Creates, writes and removes files in `dir` for `ms` milliseconds, as a
/// program that keeps SQLite databases there does: four writers, each of
/// which creates a file and writes it for 50 ms, creates, writes and
/// removes a `-journal` file beside it, then removes the first, over and
/// over. The async runtime's file watcher aborted a process that watched
/// such a directory within about a second. The writes come back to back,
/// each awaited: with a pause between them, it aborted in only about half
/// of the runs.
async fn churn(dir : String, ms~ : Int32) -> Unit {
  let end = @async.now() + ms.to_int64()
  let piece = Bytes::make(512, b'x')
  @async.with_task_group(group => {
    for writer in 0..<4 {
      group.spawn_bg(() => {
        for i = 0; @async.now() < end; i = i + 1 {
          let path = "\{dir}/w\{writer}-\{i % 20}.db"
          let file = @fs.open(
            path,
            mode=WriteOnly,
            create_mode=CreateOrTruncate,
          )
          let written = @async.now() + 50
          while @async.now() < written {
            file.write(piece)
          }
          file.close()
          let journal = @fs.open(
            "\{path}-journal",
            mode=WriteOnly,
            create_mode=CreateOrTruncate,
          )
          for _ in 0..<50 {
            journal.write(piece)
          }
          journal.close()
          @fs.remove("\{path}-journal")
          @fs.remove(path)
        }
      })
    }
  })
}

///|
/// Runs `churn` in `dir` for 3 s, and `change` 1.5 s into it, then calls
/// `found` until it gives what the change should lead to, at most
/// `reload_patience_ms`, and returns that, or "no change in time". Fails
/// when smock exits before the churn has ended, so a test that gets a value
/// back knows smock kept running. Where smock notes the names the churn
/// changes, as in the definitions directory, its stamps differ until the
/// churn stops, so the change is read then, well within the 10 s after
/// which smock reads it all the same.
async fn amid_churn(
  smock : Smock,
  dir : String,
  change~ : async () -> Unit,
  found~ : async () -> String?,
) -> String {
  let exited = () => {
    guard smock.process.try_wait() is Some(status) else { return }
    fail(
      "smock exited with status \{status} amid the churn:\n\{smock.logs.join("\n")}",
    )
  }
  let mut seen = "nothing"
  @async.with_task_group(group => {
    group.spawn_bg(() => churn(dir, ms=3000))
    @async.sleep(1500)
    exited()
    change()
    let result = wait_for(reload_patience_ms, () => {
      exited()
      found()
    })
    seen = result.unwrap_or("no change in time")
  })
  exited()
  seen
}

///|
/// The Admin API token the harness gives smock, through `SMOCK_ADMIN_TOKEN`,
/// unless a test sets that variable itself.
let test_token : String = "e2e-admin-token"

///|
/// The environment of a smock process: `env`, plus a TLS port and an admin
/// port of 0 (free ports, so tests run in parallel) and the test token,
/// unless `env` sets them.
fn smock_env(env : Map[String, String]) -> Map[String, String] {
  let out = {
    "SMOCK_TLS_PORT": "0",
    "SMOCK_ADMIN_PORT": "0",
    "SMOCK_ADMIN_TOKEN": test_token,
  }
  for name, value in env {
    out[name] = value
  }
  out
}

///|
/// A running smock process.
struct Smock {
  /// The plain port it listens on.
  port : Int32
  /// The admin port it listens on.
  admin_port : Int32
  /// The TLS port it listens on.
  tls_port : Int32
  /// Its process ID.
  pid : Int32
  /// The lines it has written to stderr so far, its log lines in the json
  /// log format: they keep coming while it runs.
  logs : Array[String]
  /// The lines it has written to stdout so far, every log line in the
  /// mockoon log format: they keep coming while it runs.
  stdout : Array[String]
  /// The process, to wait for its exit.
  process : @process.Process
}

///|
/// Sends smock SIGTERM, which makes it drain and exit.
async fn Smock::terminate(self : Smock) -> Unit {
  terminate(self.pid)
}

///|
/// Sends the process `pid` SIGTERM.
async fn terminate(pid : Int32) -> Unit {
  let _ = @process.run("kill", ["-TERM", pid.to_string()])
}

///|
/// Waits for smock to exit, and returns its exit status (minus the signal
/// number when a signal ended it).
async fn Smock::exited(self : Smock) -> Int32 {
  let status = @async.with_timeout_opt(patience_ms, () => self.process.wait())
  guard status is Some(status) else { fail("smock did not exit in time") }
  status
}

///|
/// The test PKI from `@testcerts`, written to files: the paths of the root
/// CA certificate, of two certificate chains for `localhost` and
/// `127.0.0.1` (the leaf, then the intermediate CA) with their keys, and of
/// a key that belongs to no certificate.
struct Certificates {
  dir : String
  ca : String
  rsa_chain : String
  rsa_key : String
  ecdsa_chain : String
  ecdsa_key : String
  other_key : String
}

///|
/// Writes the test PKI to a temporary directory, runs `f` with its paths
/// and removes it.
async fn with_certificates(f : async (Certificates) -> Unit) -> Unit {
  let dir = @fs.tmpdir(prefix="smock-e2e-certs-")
  defer @fs.rmdir(dir, recursive=true)
  let files = [
    ("ca.pem", @testcerts.root_ca),
    ("rsa-chain.pem", @testcerts.rsa_chain),
    ("rsa-key.pem", @testcerts.rsa_key),
    ("ecdsa-chain.pem", @testcerts.ecdsa_chain),
    ("ecdsa-key.pem", @testcerts.ecdsa_key),
    ("other-key.pem", @testcerts.other_rsa_key),
  ]
  for file in files {
    let (name, pem) = file
    write(dir, name, pem + "\n")
  }
  f({
    dir,
    ca: "\{dir}/ca.pem",
    rsa_chain: "\{dir}/rsa-chain.pem",
    rsa_key: "\{dir}/rsa-key.pem",
    ecdsa_chain: "\{dir}/ecdsa-chain.pem",
    ecdsa_key: "\{dir}/ecdsa-key.pem",
    other_key: "\{dir}/other-key.pem",
  })
}

///|
/// The flags that serve HTTPS on a free TLS port with `cert` and `key`, by
/// default the RSA chain and its key.
fn Certificates::args(
  self : Certificates,
  cert~ : String = self.rsa_chain,
  key~ : String = self.rsa_key,
) -> Array[String] {
  ["--tls-port", "0", "--tls-cert-file", cert, "--tls-key-file", key]
}

///|
/// Starts smock with a definitions directory holding `files` (by default
/// `users`), a certificate, `args` and the environment `env`, runs `f` once
/// over the plain port and once over the TLS port, and returns how smock
/// ended. The HTTP/1.1 tests run this way: the codec and the connection
/// loop are the same on both ports.
async fn on_both_ports(
  files~ : Array[(String, String)] = [("users.json", users)],
  args~ : Array[String] = [],
  env~ : Map[String, String] = Map([]),
  f : async (Smock, Over) -> Unit,
) -> Stopped {
  let mut stopped = None
  with_definitions(files, dir => {
    with_certificates(certs => {
      stopped = Some(
        with_smock(
          ["--dir", dir, "--port", "0", ..certs.args(), ..args],
          env~,
          smock => {
            for over in [Plain, Tls(certs)] {
              f(smock, over)
            }
          },
        ),
      )
    })
  })
  stopped.unwrap()
}

///|
/// How a test reaches smock: over plain TCP on the plain port, or over TLS
/// on the TLS port with a client that trusts only the test root CA and
/// checks the certificate for `localhost`.
enum Over {
  Plain
  Tls(Certificates)
}

///|
/// A connection to smock, over plain TCP or over TLS.
enum Conn {
  PlainConn(@socket.Tcp)
  TlsConn(@tls.Tls, @socket.Tcp)
}

///|
async fn Conn::write(self : Conn, data : &@io.Data) -> Unit {
  match self {
    PlainConn(tcp) => tcp.write(data)
    TlsConn(tls, _) => tls.write(data)
  }
}

///|
async fn Conn::read_until(self : Conn, separator : String) -> String? {
  match self {
    PlainConn(tcp) => tcp.read_until(separator)
    TlsConn(tls, _) => tls.read_until(separator)
  }
}

///|
async fn Conn::read_exactly(self : Conn, length : Int32) -> Bytes {
  match self {
    PlainConn(tcp) => tcp.read_exactly(length)
    TlsConn(tls, _) => tls.read_exactly(length)
  }
}

///|
async fn Conn::read_some(self : Conn) -> Bytes? {
  match self {
    PlainConn(tcp) => tcp.read_some()
    TlsConn(tls, _) => tls.read_some()
  }
}

///|
fn Conn::close(self : Conn) -> Unit {
  match self {
    PlainConn(tcp) => tcp.close()
    TlsConn(tls, tcp) => {
      tls.close()
      tcp.close()
    }
  }
}

///|
/// How a smock process ended: its exit status (minus the signal number when
/// a signal ended it), every line it wrote to stderr and every line it
/// wrote to stdout.
struct Stopped {
  status : Int32
  logs : Array[String]
  stdout : Array[String]
}

///|
/// Starts `smock serve <args>` with only `smock_env(env)` as its
/// environment, in the working directory `cwd` (by default the test's own),
/// waits until it listens on the plain, the TLS and the admin port, runs
/// `f`, then stops it with SIGTERM, unless `f` has, and waits for it to
/// exit. `under`, when given, is a command that runs smock as its last
/// arguments and becomes smock by exec, such as `systemd-run --scope ...
/// --`, so that the signal still reaches smock. With `close_stdout`, the
/// reading end of smock's stdout is closed once smock listens, so that every
/// write smock makes there after that fails.
async fn with_smock(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
  cwd~ : String = ".",
  under~ : Array[String] = [],
  close_stdout~ : Bool = false,
  f : async (Smock) -> Unit,
) -> Stopped {
  @async.with_task_group(group => {
    let serving = Serving::start(group, args, env~, cwd~, under~)
    guard serving.listening_on(["plain", "tls", "admin"]) is Some(ports) else {
      fail("smock exited before listening:\n\{serving.log().join("\n")}")
    }
    if close_stdout {
      serving.close_stdout()
    }
    f(serving.smock(ports))
    let status = serving.stop()
    { status, logs: serving.logs, stdout: serving.stdout, }
  })
}

///|
/// A `smock serve` process the harness started, while it runs.
struct Serving {
  process : @process.Process
  /// The lines it has written to stderr so far: they keep coming while it
  /// runs.
  logs : Array[String]
  /// Each log line as it comes, from stderr, or from stdout in the mockoon
  /// log format, then `None` once smock has closed that stream, which it
  /// does when it exits.
  lines : @async.Queue[String?]
  /// Reads the lines of stderr, until smock closes it.
  reader : @async.Task[Unit]
  /// The lines it has written to stdout so far.
  stdout : Array[String]
  /// Reads the lines of stdout, until smock closes it, unless its reading
  /// end was closed (`close_stdout`) or reading it stopped
  /// (`stall_stdout`).
  mut stdout_reader : @async.Task[Unit]?
  /// The reading end of stdout.
  stdout_pipe : @process.ReadFromProcess
  /// Whether reading stdout has stopped and left its reading end open
  /// (`stall_stdout`), until `close_stdout` closes it.
  stdout_stalled : Ref[Bool]
  /// Whether smock writes its log to stdout: in the mockoon log format.
  logs_to_stdout : Bool
}

///|
/// Whether `smock serve <args>`, with `env` as its environment, writes its
/// log to stdout: when `--log-format`, or else `SMOCK_LOG_FORMAT`, sets the
/// mockoon log format.
fn logs_to_stdout(args : Array[String], env : Map[String, String]) -> Bool {
  let mut format = env.get("SMOCK_LOG_FORMAT")
  for i, arg in args {
    if arg == "--log-format" && i + 1 < args.length() {
      format = Some(args[i + 1])
    } else if arg.has_prefix("--log-format=") {
      format = Some(arg["--log-format=".length():].to_owned())
    }
  }
  format is Some("mockoon")
}

///|
/// Starts `smock serve <args>` in `group`, with only `smock_env(env)` as
/// its environment, in the working directory `cwd`, under the command
/// `under` when given (see `with_smock`), and reads the lines of its stderr
/// and of its stdout as they come. Its log lines come from stderr, or from
/// stdout when a test sets the mockoon log format.
async fn[X] Serving::start(
  group : @async.TaskGroup[X],
  args : Array[String],
  env~ : Map[String, String] = Map([]),
  cwd~ : String = ".",
  under~ : Array[String] = [],
) -> Serving {
  build.wait()
  let (stderr, stderr_end) = @process.read_from_process()
  let (stdout, stdout_end) = @process.read_from_process()
  let smock = [@fs.realpath(binary), "serve", ..args]
  let command = [..under, ..smock]
  let process = @process.spawn(
    group,
    command[0],
    command[1:],
    extra_env=smock_env(env),
    inherit_env=false,
    stdout=stdout_end,
    stderr=stderr_end,
    cwd~,
    no_wait=true,
  )
  let logs_to_stdout = logs_to_stdout(args, env)
  let lines : @async.Queue[String?] = @async.Queue(kind=Unbounded)
  // Reads the lines of `output` into `into` until smock closes it, and, if
  // it carries the log, passes each on to `lines`.
  let read_lines = (
    output : @process.ReadFromProcess,
    into : Array[String],
    log : Bool,
  ) => {
    for ;; {
      let line = output.read_until("\n")
      if line is Some(line) {
        into.push(line)
      }
      if log {
        lines.put(line)
      }
      if line is None {
        break
      }
    }
  }
  let stdout_lines = []
  let stdout_stalled = Ref(false)
  let stdout_reader = group.spawn(() => {
    // Reading may stop with the reading end left open (`stall_stdout`).
    defer (if !stdout_stalled.val { stdout.close() })
    read_lines(stdout, stdout_lines, logs_to_stdout)
  })
  let logs = []
  let reader = group.spawn(() => {
    defer stderr.close()
    read_lines(stderr, logs, !logs_to_stdout)
  })
  {
    process,
    logs,
    lines,
    reader,
    stdout: stdout_lines,
    stdout_reader: Some(stdout_reader),
    stdout_pipe: stdout,
    stdout_stalled,
    logs_to_stdout,
  }
}

///|
/// The log lines smock has written so far: those of stderr, or of stdout
/// in the mockoon log format.
fn Serving::log(self : Serving) -> Array[String] {
  if self.logs_to_stdout {
    self.stdout
  } else {
    self.logs
  }
}

///|
/// Closes the reading end of smock's stdout, so that every write smock
/// makes there from now on fails, a write that waits on a stalled reader
/// (`stall_stdout`) included. The lines read so far stay.
async fn Serving::close_stdout(self : Serving) -> Unit {
  if self.stdout_stalled.val {
    self.stdout_stalled.val = false
    self.stdout_pipe.close()
  }
  guard self.stdout_reader is Some(reader) else { return }
  self.stdout_reader = None
  // Cancelling the reader closes the reading end, as it ends.
  reader.cancel()
  reader.wait() catch {
    _ => ()
  }
}

///|
/// Stops reading smock's stdout, and leaves its reading end open, as a
/// reader that has stalled does: once the pipe is full, every write smock
/// makes there waits, until `close_stdout`. The lines read so far stay.
async fn Serving::stall_stdout(self : Serving) -> Unit {
  guard self.stdout_reader is Some(reader) else { return }
  self.stdout_reader = None
  self.stdout_stalled.val = true
  reader.cancel()
  reader.wait() catch {
    _ => ()
  }
}

///|
/// Waits until smock listens on each of `listeners` (`"plain"`, `"tls"`,
/// `"admin"`) and returns their ports, or `None` when smock exits first.
async fn Serving::listening_on(
  self : Serving,
  listeners : Array[String],
) -> Map[String, Int32]? {
  let ports : Map[String, Int32] = Map([])
  let listened = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      if listeners.iter().all(listener => ports.contains(listener)) {
        break true
      }
      guard self.lines.get() is Some(line) else { break false }
      if listening(line) is Some((listener, port)) {
        ports[listener] = port
      }
    }
  })
  guard listened is Some(listened) else {
    fail("smock did not listen in time:\n\{self.log().join("\n")}")
  }
  if listened {
    Some(ports)
  } else {
    None
  }
}

///|
/// The running smock, with the ports it listens on from `ports`; a port it
/// has not opened yet is 0.
fn Serving::smock(self : Serving, ports : Map[String, Int32]) -> Smock {
  {
    port: ports.get("plain").unwrap_or(0),
    tls_port: ports.get("tls").unwrap_or(0),
    admin_port: ports.get("admin").unwrap_or(0),
    pid: self.process.pid,
    logs: self.logs,
    stdout: self.stdout,
    process: self.process,
  }
}

///|
/// Waits for smock to exit and for its last log line and its last line on
/// stdout, and returns its exit status (minus the signal number when a
/// signal ended it).
async fn Serving::wait(self : Serving) -> Int32 {
  let status = @async.with_timeout_opt(patience_ms, () => self.process.wait())
  guard status is Some(status) else { fail("smock did not stop in time") }
  self.reader.wait()
  if self.stdout_reader is Some(reader) {
    reader.wait()
  }
  status
}

///|
/// Stops smock with SIGTERM, unless it has exited, and waits for it as
/// `wait` does.
async fn Serving::stop(self : Serving) -> Int32 {
  if self.process.try_wait() is None {
    terminate(self.process.pid)
  }
  self.wait()
}

///|
/// Whether `smock serve <args>` loads its definitions: `"serves"` once it
/// listens on its plain port, which it opens once they have loaded (it is
/// then stopped), or `"exits with status <n>"` when it stops by itself
/// first.
async fn serve_verdict(args : Array[String]) -> String {
  @async.with_task_group(group => {
    let serving = Serving::start(group, ["--port", "0", ..args])
    if serving.listening_on(["plain"]) is Some(_) {
      let _ = serving.stop()
      "serves"
    } else {
      "exits with status \{serving.wait()}"
    }
  })
}

///|
/// The listener and the port of a `listening` log entry, in either log
/// format: with `msg` in the json format, `message` in the mockoon format.
fn listening(line : String) -> (String, Int32)? {
  let entry = @json.parse(line) catch { _ => return None }
  guard entry is Object(entry) &&
    (
      entry.get("msg") is Some(String("listening")) ||
      entry.get("message") is Some(String("listening"))
    ) &&
    entry.get("listener") is Some(String(listener)) &&
    entry.get("address") is Some(String(address)) else {
    return None
  }
  let colon = address.rev_find(":").unwrap_or(-1)
  try @string.parse_int(address[colon + 1:]) catch {
    _ => None
  } noraise {
    port => Some((listener, port))
  }
}

///|
/// Runs `smock <args>` with only `smock_env(env)` as its environment until
/// it exits by itself, and returns its exit status and the lines it wrote to
/// stderr and to stdout.
async fn run_smock(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
) -> Stopped {
  let (status, stdout, stderr) = smock_output(args, env=smock_env(env))
  let lines = (text : String) => {
    text
    .split("\n")
    .filter(line => line != "")
    .map(line => line.to_owned())
    .collect()
  }
  { status, logs: lines(stderr), stdout: lines(stdout), }
}

///|
/// Runs `smock <args>` until it exits, and returns its exit status and what
/// it wrote to stdout, such as help text.
async fn smock_stdout(args : Array[String]) -> (Int32, String) {
  let (status, stdout, _) = smock_output(args)
  (status, stdout)
}

///|
/// Runs `smock <args>` with only `env` as its environment, in the working
/// directory `cwd` (by default the test's own), until it exits by itself,
/// and returns its exit status and what it wrote to stdout and to stderr.
async fn smock_output(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
  cwd~ : String = ".",
) -> (Int32, String, String) {
  build.wait()
  let smock = @fs.realpath(binary)
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_output(smock, args, extra_env=env, inherit_env=false, cwd~)
  })
  guard result is Some((status, stdout, stderr)) else {
    fail("smock \{args.join(" ")} did not exit in time")
  }
  (status, stdout.text(), stderr.text())
}

///|
/// Renders how a run of smock ended, as `smock_output` returns it: the exit
/// status, then what smock wrote to stdout and, if anything, to stderr.
fn exit_report(output : (Int32, String, String)) -> String {
  let (status, stdout, stderr) = output
  let out = "status \{status}\n\{stdout}"
  match stderr {
    "" => out
    err => "\{out}stderr:\n\{err}"
  }
}

///|
/// Sends `GET path` with a real HTTP client and renders the response: the
/// status, the headers and the body.
async fn Smock::get(self : Smock, path : String) -> String {
  let client = @http.Client("http://127.0.0.1:\{self.port}")
  defer client.close()
  let response = client.get(path)
  let body = client.read_all().text()
  render_response(response, body)
}

///|
/// Sends one request to the Admin API and reads the whole response. It fails
/// the test unless the response conforms to the OpenAPI document
/// (`conforms`), so every Admin API response a test gets is checked.
///
/// - `token` goes in `Authorization: Bearer <token>`; `None` sends no
///   Authorization field. The default is the token the harness gives smock.
/// - `headers` are sent after Host and Authorization.
/// - `body`, when given, is sent with its Content-Length.
async fn Smock::admin(
  self : Smock,
  meth : String,
  path : String,
  token~ : String? = Some(test_token),
  headers~ : Array[(String, String)] = [],
  body? : String,
) -> AdminResponse {
  let conn = PlainConn(
    @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.admin_port}")),
  )
  defer conn.close()
  let authorization = match token {
    Some(token) => [("Authorization", "Bearer \{token}")]
    None => []
  }
  conn.write(
    raw_request(
      meth,
      path,
      host="localhost",
      headers=[..authorization, ..headers],
      body?,
    ),
  )
  let response = read_admin_response(conn)
  conforms(meth, path, response)
  response
}

///|
/// An Admin API response as a test sees it.
struct AdminResponse {
  status : Int32
  /// The header fields, in the order they came.
  headers : Array[(String, String)]
  body : String
}

///|
/// The value of the header field `name`, compared case-insensitively.
fn AdminResponse::header(self : AdminResponse, name : String) -> String? {
  let name = name.to_lower()
  for header in self.headers {
    if header.0.to_lower() == name {
      return Some(header.1)
    }
  }
  None
}

///|
/// The body, parsed as JSON.
fn AdminResponse::json(self : AdminResponse) -> Json raise {
  @json.parse(self.body)
}

///|
/// Reads one response and parses its status and header fields.
async fn read_admin_response(conn : Conn) -> AdminResponse {
  guard read_framed(conn) is Some((head, body)) else {
    fail("the connection closed without a response")
  }
  let lines = head.split("\r\n").collect()
  let status = @string.parse_int(lines[0].split(" ").nth(1).unwrap())
  let headers = []
  for line in lines[1:] {
    guard line.find(":") is Some(colon) else { continue }
    headers.push((line[:colon].to_owned(), line[colon + 1:].trim().to_owned()))
  }
  AdminResponse::{ status, headers, body: @utf8.decode(body), }
}

///|
/// A request as raw HTTP/1.1 bytes: the request line, `Host: <host>` when
/// `host` is given, `headers` in order, then, when `body` is given, its
/// Content-Length and the body.
fn raw_request(
  meth : String,
  target : String,
  host? : String,
  headers~ : Array[(String, String)] = [],
  body? : String,
) -> String {
  let out = StringBuilder()
  out.write_string("\{meth} \{target} HTTP/1.1\r\n")
  if host is Some(host) {
    out.write_string("Host: \{host}\r\n")
  }
  for header in headers {
    out.write_string("\{header.0}: \{header.1}\r\n")
  }
  match body {
    Some(body) =>
      out.write_string(
        "Content-Length: \{@utf8.encode(body).length()}\r\n\r\n\{body}",
      )
    None => out.write_string("\r\n")
  }
  out.to_string()
}

///|
/// Reads one response, framed by its Content-Length: its head, without the
/// empty line that ends it, and its body. `None` when the connection ends
/// first.
async fn read_framed(conn : Conn) -> (String, Bytes)? {
  let result = @async.with_timeout_opt(patience_ms, () => {
    guard conn.read_until("\r\n\r\n") is Some(head) else { return None }
    let mut length = 0
    for line in head.split("\r\n") {
      if line.to_lower().has_prefix("content-length:") {
        length = @string.parse_int(line["content-length:".length():].trim())
      }
    }
    Some((head, conn.read_exactly(length)))
  })
  guard result is Some(response) else { fail("no response in time") }
  response
}

///|
/// Opens a connection to smock for tests that send exact bytes: over plain
/// TCP by default, or over TLS.
async fn Smock::connect(self : Smock, over~ : Over = Plain) -> Conn {
  match over {
    Plain =>
      PlainConn(
        @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.port}")),
      )
    Tls(certs) => {
      let tcp = @socket.Tcp::connect(
        @socket.Addr::parse("127.0.0.1:\{self.tls_port}"),
      )
      errdefer tcp.close()
      let tls = @tls.Tls::client(
        tcp,
        host="localhost",
        trust=CustomPemFile(certs.ca),
      )
      TlsConn(tls, tcp)
    }
  }
}

///|
/// Reads one response, framed by its Content-Length, and renders it with
/// `\r\n` shown as `\n` and the current Date masked (`mask_date`). Returns
/// `"closed"` when the connection ends first.
async fn read_response(conn : Conn) -> String {
  match read_framed(conn) {
    Some((head, body)) =>
      mask_date(head.replace_all(old="\r\n", new="\n")) +
      "\n\n" +
      @utf8.decode_lossy(body)
    None => "closed"
  }
}

///|
/// `text`, one or more responses or parts of them, with the value of each
/// `Date` field that is the current time shown as `<now>`: the time, by the
/// test's clock, of a second within the last minute, in IMF-fixdate form.
/// Any other value stays as it is, such as an older one a Stub gives, so a
/// Date that is missing, repeated, late or malformed shows.
fn mask_date(text : String) -> String {
  guard text.contains("Date: ") else { return text }
  let dates = @http1.DateCache()
  let now = @async.now() / 1000L
  let recent = []
  for second in (now - 60L)..<=(now + 1L) {
    recent.push(dates.at(second * 1000L))
  }
  text
  .split("\n")
  .map(line => {
    guard line.strip_prefix("Date: ") is Some(value) else {
      return line.to_owned()
    }
    let (value, cr) = match value.strip_suffix("\r") {
      Some(value) => (value, "\r")
      None => (value, "")
    }
    if recent.contains(value.to_owned()) {
      "Date: <now>\{cr}"
    } else {
      line.to_owned()
    }
  })
  .collect()
  .join("\n")
}

///|
/// Whether smock closes the connection without sending anything more.
async fn closed(conn : Conn) -> Bool {
  let result = @async.with_timeout_opt(patience_ms, () => conn.read_some())
  guard result is Some(rest) else { fail("the connection stayed open") }
  rest is None
}

///|
/// Reads `conn` until smock ends it, by a FIN or a reset alike, and returns
/// when the last bytes came (-1 if none did) and when the end came, in
/// milliseconds after `since`, and every byte received.
async fn received_until_end(
  conn : Conn,
  since : Int64,
) -> (Int64, Int64, Bytes) {
  let received = @buffer.Buffer()
  let mut last = -1L
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let more = conn.read_some() catch { _ => None }
      guard more is Some(bytes) else { break }
      last = @async.now() - since
      received.write_bytes(bytes)
    }
  })
  guard result is Some(_) else { fail("the connection stayed open") }
  (last, @async.now() - since, received.to_bytes())
}

///|
fn render_response(response : @http.Response, body : String) -> String {
  let out = StringBuilder()
  out.write_string("\{response.code} \{response.reason}\n")
  for name, value in response.headers {
    out.write_string("\{name.0}: \{value}\n")
  }
  out.write_string("\n")
  mask_date(out.to_string()) + body
}

///|
/// The log lines as JSON objects without their time, with the values that
/// differ from build to build and run to run replaced by `*`. The Journal's
/// byte bound and the per-Session state's differ from machine to machine
/// unless a flag or a variable sets them: they follow the memory limit of
/// smock's cgroup. Then a bound, its source and the memory limit, or why it
/// could not be read, are all `*`, as `memoryLimit`.
fn log_entries(logs : Array[String]) -> String {
  logs
  .map(line => {
    let entry = @json.parse(line) catch { _ => return "not JSON: \{line}" }
    guard entry is Object(fields) else { return "not an object: \{line}" }
    let from_memory_limit = fields.get("msg")
      is Some(String("journal byte bound" | "state byte bound")) &&
      !(fields.get("source") is Some(String("flag" | "variable")))
    let out : Map[String, Json] = Map([])
    for key, value in fields {
      match key {
        "time" => ()
        "maxBytes" | "source" if from_memory_limit => out[key] = "*"
        "memoryLimit" | "memoryLimitError" if from_memory_limit =>
          out["memoryLimit"] = "*"
        "version" | "commit" | "toolchain" | "seed" | "sha256Fingerprint" =>
          out[key] = "*"
        "certFile" | "keyFile" =>
          out[key] = match value {
            String(path) =>
              Json::string(
                "*/" + path[path.rev_find("/").unwrap_or(-1) + 1:].to_owned(),
              )
            _ => value
          }
        "address" =>
          out[key] = match value {
            String(address) =>
              Json::string(
                address[:address.rev_find(":").unwrap_or(0)].to_owned() + ":*",
              )
            _ => value
          }
        _ => out[key] = value
      }
    }
    Json::object(out).stringify()
  })
  .join("\n")
}

///|
/// The log entry with the message `msg`, without its time.
fn startup_entry(logs : Array[String], msg : String) -> String {
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(fields) &&
      fields.get("msg") is Some(String(m)) &&
      m == msg else {
      continue
    }
    fields.remove("time")
    return Json::object(fields).stringify()
  }
  "no \{msg} entry in:\n\{logs.join("\n")}"
}

///|
/// Runs `smock check <args>` with only `env` as its environment until it
/// exits, and renders its exit status, then what it wrote to stdout and,
/// if anything, to stderr.
async fn check(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
) -> String {
  exit_report(smock_output(["check", ..args], env~))
}

///|
/// A Stub that answers `/users/1` whatever the method.
let any_method : String =
  #|{
  #|  "mocks": [{ "name": "users" }],
  #|  "stubs": [
  #|    {
  #|      "id": "user",
  #|      "mock": "users",
  #|      "request": { "path": "/users/1" },
  #|      "response": {
  #|        "status": 200,
  #|        "headers": { "Content-Type": "application/json" },
  #|        "body": "{\"id\":1,\"name\":\"Alice\"}"
  #|      }
  #|    }
  #|  ]
  #|}

///|
/// The log lines of a smock process, serving both ports, that wrote nothing
/// between starting and draining when it was stopped.
let startup_only : String =
  #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
  #|{"level":"info","msg":"random seed","seed":"*"}
  #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
  #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
  #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*","protocols":["http/1.1"]}
  #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*","protocols":["http/1.1","h2c"]}
  #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","protocols":["h2","http/1.1"],"certFile":"*/rsa-chain.pem","keyFile":"*/rsa-key.pem"}
  #|{"level":"info","msg":"drain started","timeoutMs":20000}
  #|{"level":"info","msg":"drain ended","connectionsCut":0}

///|
/// Reads a response head without a body, as sent for HEAD or for a 1xx
/// status, and renders it with `\r\n` shown as `\n` and the current Date
/// masked (`mask_date`), without the empty line that ends it.
async fn read_head(conn : Conn) -> String {
  let result = @async.with_timeout_opt(patience_ms, () => {
    conn.read_until("\r\n\r\n")
  })
  guard result is Some(head) else { fail("no response head in time") }
  match head {
    Some(head) => mask_date(head.replace_all(old="\r\n", new="\n")) + "\n"
    None => "closed"
  }
}

///|
/// The status line of `response`, as `read_response` renders it.
fn status_line(response : String) -> String {
  response[:response.find("\n").unwrap_or(response.length())].to_owned()
}

///|
/// Waits until smock ends the connection, and returns how many milliseconds
/// after `since` that was and what smock sent until then, with the current
/// Date masked (`mask_date`). A reset ends the connection too.
async fn ended(conn : Conn, since : Int64) -> (Int64, String) {
  let (_, end, received) = received_until_end(conn, since)
  (end, mask_date(@utf8.decode_lossy(received)))
}

///|
/// A Mock whose `/slow` answers after a delay of 1000 ms and whose
/// `/events` streams three events over 1200 ms: both outlast the timeouts
/// that the tests which use it set.
let outlasting : String =
  #|{ "mocks": [{ "name": "users" }],
  #|  "stubs": [
  #|    { "id": "slow", "mock": "users", "request": { "path": "/slow" },
  #|      "response": { "status": 200, "body": "slow" },
  #|      "fault": { "delay": { "fixed": 1000 } } },
  #|    { "id": "stream", "mock": "users", "request": { "path": "/events" },
  #|      "response": { "status": 200,
  #|        "events": [
  #|          { "delay": 400, "data": "first" },
  #|          { "delay": 400, "data": "second" },
  #|          { "delay": 400, "data": "last" } ] } } ] }

///|
/// The ticket's example: the Mock `shop` with the bucket `orders`, keyed by
/// `id`, from `files/orders.json`, which holds three orders, and `visits`,
/// without `key`; `GET /api/v1/orders` answers `orders`.
let shop_orders : Array[(String, String)] = [
  (
    "shop.yaml",
    (
      #|mocks:
      #|  - name: shop
      #|data:
      #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
      #|  - { mock: shop, name: visits, json: 0 }
      #|stubs:
      #|  - id: list-orders
      #|    mock: shop
      #|    request: { method: GET, path: /api/v1/orders }
      #|    response: { status: 200, template: true, json: "${data.orders}" }
    ),
  ),
  (
    "files/orders.json",
    (
      #|[{ "id": 1, "status": "paid" }, { "id": 2, "status": "pending" },
      #| { "id": 3, "status": "paid" }]
    ),
  ),
]

///|
/// A Definition file declaring one Stub of Mock `m` that answers `GET path`
/// with 200 and `body`.
fn stub_file(id : String, path : String, body : String) -> String {
  (
    $|{ "stubs": [{ "id": "\{id}", "mock": "m",
    $|  "request": { "method": "GET", "path": "\{path}" },
    $|  "response": { "status": 200, "body": "\{body}" } }] }
  )
}

///|
/// Mock `m`, whose Stubs answer `GET /fast` at once, `GET /slow` after a
/// delay of 1000 ms, `GET /stalled` after a delay of 60 s, `GET /ticks` with
/// a stream of 100 events, one every 100 ms, and `GET /brief` with a stream
/// of 10 such events.
let drain_defs : String = {
  let tick = "{ \"delay\": 100, \"data\": \"tick\" }"
  let ticks = Array::make(100, tick)
  let brief = Array::make(10, tick)
  let defs =
    $|{ "mocks": [{ "name": "m" }],
    $|  "stubs": [
    $|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
    $|      "response": { "status": 200, "body": "fast" } },
    $|    { "id": "slow", "mock": "m", "request": { "path": "/slow" },
    $|      "response": { "status": 200, "body": "slow" },
    $|      "fault": { "delay": { "fixed": 1000 } } },
    $|    { "id": "stalled", "mock": "m", "request": { "path": "/stalled" },
    $|      "response": { "status": 200, "body": "stalled" },
    $|      "fault": { "delay": { "fixed": 60000 } } },
    $|    { "id": "ticks", "mock": "m", "request": { "path": "/ticks" },
    $|      "response": { "status": 200, "events": [\{ticks.join(", ")}] } },
    $|    { "id": "brief", "mock": "m", "request": { "path": "/brief" },
    $|      "response": { "status": 200, "events": [\{brief.join(", ")}] } } ] }
  defs
}

///|
/// How long a test waits after sending a request before it sends SIGTERM,
/// so that smock has received the request by then.
let settle_ms : Int32 = 300

///|
/// The log entries about the drain, without their time.
fn drain_entries(logs : Array[String]) -> String {
  let out = []
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(fields) &&
      fields.get("msg") is Some(String(msg)) &&
      msg.contains("drain") else {
      continue
    }
    fields.remove("time")
    out.push(Json::object(fields).stringify())
  }
  out.join("\n")
}

///|
/// Reads `conn` until smock ends it, and returns when the last bytes came
/// and when the end came, in milliseconds after `since`, and every byte
/// received, with `\r\n` shown as `\n`.
async fn until_end(conn : Conn, since : Int64) -> (Int64, Int64, String) {
  let (last, end, received) = received_until_end(conn, since)
  (last, end, @utf8.decode_lossy(received).replace_all(old="\r\n", new="\n"))
}

///|
/// Mock `m` with Stubs that answer `GET /slow` after a fixed delay of
/// 1500 ms, `GET /fast` at once, `/reset` by resetting the connection,
/// `GET /close` by closing the connection, `GET /partial` with half its
/// body, `GET /coin` by closing the connection half of the time, as the
/// process generator decides, and `GET /flaky` by resetting the connection
/// half of the time, as the Stub's own generator, seeded, decides.
let faults : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "slow", "mock": "m", "request": { "path": "/slow" },
  #|      "response": { "status": 200, "body": "slow" },
  #|      "fault": { "delay": { "fixed": 1500 } } },
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
  #|      "fault": { "connection": { "kind": "partial", "probability": 1 } } },
  #|    { "id": "coin", "mock": "m", "request": { "path": "/coin" },
  #|      "response": { "status": 200, "body": "heads" },
  #|      "fault": { "connection": { "kind": "close", "probability": 0.5 } } },
  #|    { "id": "flaky", "mock": "m", "request": { "path": "/flaky" },
  #|      "response": { "status": 200, "body": "answered" },
  #|      "fault": { "connection": { "kind": "reset", "probability": 0.5 },
  #|        "seed": 2026 } } ] }

///|
/// Every byte smock sends on `conn` until it closes the connection with a
/// FIN, with `\r\n` shown as `\n` and the current Date masked
/// (`mask_date`). A reset fails the test.
async fn read_to_end(conn : Conn) -> String {
  let received = @buffer.Buffer()
  let result = @async.with_timeout_opt(patience_ms, () => {
    while conn.read_some() is Some(bytes) {
      received.write_bytes(bytes)
    }
  })
  guard result is Some(_) else { fail("the connection stayed open") }
  mask_date(
    @utf8.decode_lossy(received.to_bytes()).replace_all(old="\r\n", new="\n"),
  )
}

///|
/// Whether `err` is the error a read gets when the peer resets the
/// connection, ECONNRESET.
fn is_reset(err : @os_error.OSError) -> Bool {
  err.to_string().contains("Connection reset by peer")
}

///|
/// How smock ends `conn`, waiting at most `within` milliseconds: how many
/// bytes it sends first, then whether an RST (a connection-reset error) or
/// a FIN (a clean end of stream) ends the connection, or it stays open.
async fn how_it_ends(conn : Conn, within~ : Int32 = patience_ms) -> String {
  let (received, ending) = sent_until_end(conn, within~)
  "\{received.length()} bytes, then \{ending}"
}

///|
/// Every byte smock sends on `conn` until the connection ends, waiting at
/// most `within` milliseconds, and how it ends: `an RST`, `a FIN`, or
/// `nothing yet: it is still open`.
async fn sent_until_end(conn : Conn, within~ : Int32) -> (Bytes, String) {
  let received = @buffer.Buffer()
  let ending = @async.with_timeout_opt(within, () => {
    for ;; {
      let bytes = conn.read_some() catch {
        @os_error.OSError(_, ..) as err if is_reset(err) => break "an RST"
        err => break "an error: \{err}"
      }
      guard bytes is Some(bytes) else { break "a FIN" }
      received.write_bytes(bytes)
    }
  })
  (received.to_bytes(), ending.unwrap_or("nothing yet: it is still open"))
}

///|
/// Two Mocks with Hosts, `users` marked default and `orders`, each with a
/// Stub `GET /x` that answers with its name. With `default=false`, neither
/// is the Default Mock.
fn two_mocks(default~ : Bool) -> Array[(String, String)] {
  [
    (
      "orders.json",
      (
        #|{ "mocks": [{ "name": "orders", "hosts": ["orders.example.com"] }],
        #|  "stubs": [{ "id": "orders-x", "mock": "orders",
        #|    "request": { "method": "GET", "path": "/x" },
        #|    "response": { "status": 200, "body": "from orders" } }] }
      ),
    ),
    (
      "users.json",
      (
        $|{ "mocks": [{ "name": "users", "hosts": ["users.example.com", "[::1]:8080"],
        $|    "default": \{default} }],
        $|  "stubs": [{ "id": "users-x", "mock": "users",
        $|    "request": { "method": "GET", "path": "/x" },
        $|    "response": { "status": 200, "body": "from users" } }] }
      ),
    ),
  ]
}

///|
/// Sends each request in `requests` on its own connection, as
/// `Smock::exchange` does, and renders the responses, separated by `---`.
async fn exchange_each(
  smock : Smock,
  over : Over,
  requests : Array[String],
) -> String {
  let out = []
  for request in requests {
    out.push(smock.exchange(over, request))
  }
  out.join("\n---\n")
}

///|
/// Runs `smock import-openapi <args>` in the working directory `cwd` until
/// it exits, and renders its exit status, then what it wrote to stdout and,
/// if anything, to stderr, with `dir` written `<dir>`.
async fn import_openapi(
  args : Array[String],
  dir~ : String = "",
  cwd~ : String = ".",
) -> String {
  let report = exit_report(smock_output(["import-openapi", ..args], cwd~))
  if dir == "" {
    report
  } else {
    report.replace_all(old=dir, new="<dir>")
  }
}

///|
/// The entries of the Journal of `session`, in order, each an object.
/// Fails when the Journal or an entry is not as smock writes it.
async fn Smock::journal_entries(
  self : Smock,
  session : String,
) -> Array[Map[String, Json]] {
  let entries = match self.journal(session~) {
    (200, Object({ "entries": Array(entries), .. })) => entries
    (status, body) => fail("unexpected Journal: \{status} \{body.stringify()}")
  }
  let objects = []
  for entry in entries {
    guard entry is Object(entry) else {
      fail("unexpected entry: \{entry.stringify()}")
    }
    objects.push(entry)
  }
  objects
}

///|
/// What the Journal holds for `session`, in order: for each request, the
/// Mock and the Stub that answered, and the status.
async fn Smock::answered_by(self : Smock, session : String) -> Json {
  let answered : Array[Json] = []
  for entry in self.journal_entries(session) {
    answered.push({
      "mock": entry.get("mock").unwrap_or(Json::null()),
      "stub": entry.get("stub").unwrap_or(Json::null()),
      "status": entry.get("status").unwrap_or(Json::null()),
    })
  }
  Json::array(answered)
}

///|
/// The memory limit of the scopes smock runs in here: 52Mi, that of the
/// smallest GKE Autopilot Pod where Pods may burst, in whole pages of 4 KiB
/// and of 16 KiB.
let scope_memory_max : String = "54525952"

///|
/// The command that runs the command after it in a new systemd user scope
/// whose cgroup has the memory limit `scope_memory_max`. It becomes that
/// command by exec, so the command keeps its process ID.
let in_scope : Array[String] = [
  "systemd-run",
  "--user",
  "--scope",
  "--quiet",
  "--collect",
  "-p",
  "MemoryMax=\{scope_memory_max}",
  "--",
]

///|
/// What `systemd-run --user` needs from the environment to reach the
/// systemd user manager, since the harness gives smock no other variables.
fn user_manager_env(env : Map[String, String]) -> Map[String, String] {
  let out = Map::from_iter(env.iter())
  for name in ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
    if @env.get_env_var(name) is Some(value) {
      out[name] = value
    }
  }
  out
}

///|
/// Why smock cannot run in a scope with a memory limit here, or `None` when
/// it can: a shell run as `in_scope` prints its own cgroup's memory.max,
/// which must be the scope's limit.
async fn scope_unavailable() -> String? {
  let script = "cat \"/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)/memory.max\""
  let command = [..in_scope, "sh", "-c", script]
  let (status, output) = @process.collect_output_merged(
    command[0],
    command[1:].to_owned(),
  ) catch {
    err => return Some("systemd-run cannot be run: \{err}")
  }
  let text = output.text().trim(chars="\n").to_owned()
  if status != 0 {
    Some("systemd-run --user failed with exit status \{status}: \{text}")
  } else if text != scope_memory_max {
    Some(
      "a scope with MemoryMax=\{scope_memory_max} got memory.max \{text.escape()}: the systemd user manager needs the memory controller delegated to it (see bench/README.md)",
    )
  } else {
    None
  }
}

///|
/// The value of the sample `name` without labels in the Prometheus `text`.
fn metric_value(text : String, name : String) -> Double raise {
  for line in metric_lines(text, name + " ") {
    return @string.parse_double(line[name.length() + 1:]) catch { _ => break }
  }
  fail("no sample \{name} in:\n\{text}")
}

///|
/// Two Mocks for their own Hosts, without a Default Mock: `users`, with a
/// Stub, Stubs whose connection Faults close the connection or send half a
/// response, and a stream of Server-Sent Events; and `orders`, whose
/// Journal is off.
let journal_defs : String =
  #|{ "mocks": [
  #|    { "name": "users", "hosts": ["users.example.com", "localhost"] },
  #|    { "name": "orders", "hosts": ["orders.example.com"], "journal": false } ],
  #|  "stubs": [
  #|    { "id": "get-user", "mock": "users",
  #|      "request": { "method": "GET", "path": { "pattern": "/users/[0-9]+" } },
  #|      "response": { "status": 200, "body": "Alice" } },
  #|    { "id": "close", "mock": "users", "request": { "path": "/close" },
  #|      "response": { "status": 200 },
  #|      "fault": { "connection": { "kind": "close" } } },
  #|    { "id": "partial", "mock": "users", "request": { "path": "/partial" },
  #|      "response": { "status": 200, "body": "0123456789" },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "events", "mock": "users", "request": { "path": "/events" },
  #|      "response": { "status": 200, "events": [
  #|        { "delay": 300, "data": "first" },
  #|        { "delay": 300, "data": "second" },
  #|        { "delay": 300, "data": "last" } ] } },
  #|    { "id": "get-order", "mock": "orders", "request": { "path": "/orders/1" },
  #|      "response": { "status": 200 } } ] }

///|
/// Queries the Journal as `session`, with the query `query`, checks the
/// response against the document, and returns its status and body.
async fn Smock::journal(
  self : Smock,
  session? : String,
  query~ : String = "{}",
) -> (Int32, Json) {
  let response = self.admin(
    "POST",
    "/v1/journal/query",
    headers=session_headers(session),
    body=query,
  )
  (response.status, response.json())
}

///|
/// The number of entries a query as `session` with `query` returns.
async fn Smock::journal_count(
  self : Smock,
  session : String,
  query : String,
) -> Int32 {
  match self.journal(session~, query~) {
    (200, Object({ "entries": Array(entries), .. })) => entries.length()
    (status, body) => fail("the query failed: \{status} \{body.stringify()}")
  }
}

///|
/// `json` with the values that differ from run to run replaced: when the
/// entries were received, how long they took and the digest.
fn journal_shown(json : Json) -> Json {
  match json {
    Object(members) => {
      let out = Map([])
      for name, value in members {
        out[name] = match (name, value) {
          ("receivedAt", String(_)) => Json::string("<time>")
          ("durationMs", Number(_, ..)) => Json::string("<ms>")
          ("digest", String(_)) => Json::string("<digest>")
          _ => journal_shown(value)
        }
      }
      Json::object(out)
    }
    Array(items) => Json::array(items.map(journal_shown))
    _ => json
  }
}

///|
/// Sends `<meth> <target>` as raw bytes on a new connection to the plain
/// port, with `headers` and `body` and no Host field but the one `headers`
/// may hold, and reads the response.
async fn Smock::request(
  self : Smock,
  meth : String,
  target : String,
  headers~ : Array[(String, String)] = [],
  body~ : String = "",
) -> String {
  let conn = self.connect()
  defer conn.close()
  conn.write(raw_request(meth, target, headers~, body~))
  read_response(conn)
}

///|
/// A Mock that answers Chat Completions requests with an LLM response, its
/// seed fixing the reply's id.
let openai_chat : String =
  #|{ "mocks": [{ "name": "openai" }],
  #|  "stubs": [{ "id": "chat", "mock": "openai",
  #|    "request": { "method": "POST", "path": "/v1/chat/completions" },
  #|    "response": { "status": 200,
  #|      "headers": { "x-ratelimit-remaining-requests": "59" },
  #|      "llm": { "api": "openai-chat", "text": "Hello! 天気は晴れ 👍" } },
  #|    "fault": { "seed": 7 } }] }

///|
/// `text` with the value of each of its `"created":` members shown as
/// `<received>` when it is a second from `from` to `to` (milliseconds since
/// the Unix epoch). Any other value stays as it is.
fn mask_created(text : String, from~ : Int64, to~ : Int64) -> String {
  let key = "\"created\":"
  let out = StringBuilder()
  let mut rest = text
  while rest.find(key) is Some(start) {
    let digits = start + key.length()
    let mut end = digits
    while end < rest.length() && rest[end] >= '0' && rest[end] <= '9' {
      end += 1
    }
    let seconds = @string.parse_int64(rest[digits:end]) catch { _ => -1L }
    out.write_string(rest[:digits].to_owned())
    if seconds >= from / 1000L && seconds <= to / 1000L {
      out.write_string("<received>")
    } else {
      out.write_string(rest[digits:end].to_owned())
    }
    rest = rest[end:].to_owned()
  }
  out.write_string(rest)
  out.to_string()
}

///|
/// The JSON body of a Chat Completions request for `gpt-6-astra` whose
/// `stream` member is `stream`, given as JSON text.
fn chat_request(stream : String) -> String {
  "{\"model\":\"gpt-6-astra\",\"stream\":\{stream},\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}"
}

///|
/// A Mock `openai` whose Stub `paced` streams `Hi there!` in three pieces,
/// the first 1000 ms after the head, which leaves a slow runner room to
/// read the head and the opening chunk before it, and each later one 300 ms
/// after the one before, its seed fixing its request id. `/v1/ticks` streams 200 pieces, one every 50 ms, which would
/// last 10 s, and `/hello` answers at once.
let paced_openai : String =
  $|{ "mocks": [{ "name": "openai" }],
  $|  "stubs": [
  $|    { "id": "paced", "mock": "openai",
  $|      "request": { "method": "POST", "path": "/v1/chat/completions" },
  $|      "response": { "status": 200,
  $|        "llm": { "api": "openai-chat", "text": "Hi there!",
  $|          "timing": { "first": { "fixed": 1000 }, "interval": { "fixed": 300 } } } },
  $|      "fault": { "seed": 7 } },
  $|    { "id": "ticks", "mock": "openai",
  $|      "request": { "method": "POST", "path": "/v1/ticks" },
  $|      "response": { "status": 200,
  $|        "llm": { "api": "openai-chat", "text": "\{"tick".repeat(200)}",
  $|          "timing": { "first": { "fixed": 50 }, "interval": { "fixed": 50 } } } } },
  $|    { "id": "hello", "mock": "openai", "request": { "path": "/hello" },
  $|      "response": { "status": 200, "body": "hello" } } ] }

///|
/// What the Chat Completions chunk `event`, as read from the wire, carries:
/// the opening chunk, a piece, the closing chunk or the end marker.
fn chunk_carries(event : String) -> String {
  let data = event[event.find("data: ").unwrap_or(0) + 6:].to_owned()
  let json = @json.parse(data) catch { _ => return data.trim().to_owned() }
  match json {
    { "choices": [{ "delta": { "role": _, .. }, .. }], .. } => "opening chunk"
    { "choices": [{ "delta": { "content": String(piece), .. }, .. }], .. } =>
      "piece \{piece.escape()}"
    { "choices": [{ "finish_reason": String(_), .. }], .. } => "closing chunk"
    _ => data
  }
}

///|
/// The version, the commit and the toolchain in a `smock --version` line,
/// such as `smock 1.2.3 (commit 0123456789ab, moonc v0.10.20+65efd5b93)`.
fn version_parts(line : String) -> (String, String, String) raise {
  let line = line.trim()
  guard line.strip_prefix("smock ") is Some(rest) &&
    rest.find(" (commit ") is Some(i) &&
    rest[i + " (commit ".length():].strip_suffix(")") is Some(inner) &&
    inner.find(", ") is Some(j) else {
    fail("not a version line: \{line}")
  }
  (
    rest[:i].to_owned(),
    inner[:j].to_owned(),
    inner[j + ", ".length():].to_owned(),
  )
}

///|
/// The probes, in the order the tests show them.
let probes : Array[String] = ["/startupz", "/readyz", "/livez"]

///|
/// Each probe's answer, without a token, as `<path>: <status> <body>`, one
/// per line, each checked against the document.
async fn Smock::probes(self : Smock) -> String {
  let out = []
  for path in probes {
    let response = self.admin("GET", path, token=None)
    out.push("\{path}: \{response.status} \{response.body}")
  }
  out.join("\n")
}

///|
/// The resident set size of process `pid`, in bytes: VmRSS of
/// /proc/<pid>/status, in KiB.
async fn resident_set(pid : Int32) -> Double {
  for line in @fs.read_file("/proc/\{pid}/status").text().split("\n") {
    if line.strip_prefix("VmRSS:") is Some(rest) &&
      rest.trim().strip_suffix(" kB") is Some(kib) {
      return @string.parse_double(kib.trim()) * 1024.0
    }
  }
  fail("no VmRSS in /proc/\{pid}/status")
}

///|
/// Mock `media` with `GET /video.mp4`, which answers 200 from the body file
/// `video.mp4`, and `GET /cut.mp4`, which answers the same with a partial
/// Fault.
let media_definitions : String =
  #|mocks:
  #|  - name: media
  #|stubs:
  #|  - id: get-video
  #|    mock: media
  #|    request: { method: GET, path: /video.mp4 }
  #|    response:
  #|      status: 200
  #|      headers: { Content-Type: video/mp4 }
  #|      bodyFile: video.mp4
  #|  - id: cut-video
  #|    mock: media
  #|    request: { method: GET, path: /cut.mp4 }
  #|    response:
  #|      status: 200
  #|      headers: { Content-Type: video/mp4 }
  #|      bodyFile: video.mp4
  #|    fault: { connection: { kind: partial } }

///|
/// The definitions directory of `media_definitions`, with the 26 letters
/// as `video.mp4`.
let media_files : Array[(String, String)] = [
  ("media.yaml", media_definitions),
  ("files/video.mp4", "abcdefghijklmnopqrstuvwxyz"),
]

///|
/// The status, checked against the document.
async fn Smock::status(self : Smock) -> Map[String, Json] {
  let response = self.admin("GET", "/v1/status")
  guard response.json() is Object(status) else { fail(response.body) }
  status
}

///|
/// Waits until status shows another last reload than `before` does, at
/// most `within` milliseconds, and returns that status.
async fn Smock::reloaded(
  self : Smock,
  before : Map[String, Json],
  within~ : Int32 = reload_patience_ms,
) -> Map[String, Json] {
  let previous = before.get("lastReload")
  let status = wait_for(within, () => {
    let status = self.status()
    if status.get("lastReload") != previous {
      Some(status)
    } else {
      None
    }
  })
  guard status is Some(status) else {
    fail("no reload in time; status: \{Json::object(before).stringify()}")
  }
  status
}

///|
/// The status and the body of the response to `GET path`, on one line.
async fn Smock::brief(self : Smock, path : String) -> String {
  let client = @http.Client("http://127.0.0.1:\{self.port}")
  defer client.close()
  let response = client.get(path)
  "\{response.code} \{client.read_all().text()}"
}

///|
/// The last reload of `status`: its result, then its errors, if any.
fn last_reload(status : Map[String, Json]) -> String {
  match status.get("lastReload") {
    Some(Object(reload)) => {
      let out = StringBuilder()
      out.write_string(reload.get("result").map_or("?", r => r.stringify()))
      if reload.get("errors") is Some(Array(errors)) {
        for error in errors {
          out.write_string("\n  \{error.stringify()}")
        }
      }
      out.to_string()
    }
    other => other.map_or("missing", r => r.stringify())
  }
}

///|
/// The log entries about reloads, without their time, with each digest in
/// `digests` shown as its name.
fn reload_entries(
  logs : Array[String],
  digests : Array[(String, Json?)],
) -> String {
  let out = []
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(fields) &&
      fields.get("msg") is Some(String(msg)) &&
      msg.contains("reload") else {
      continue
    }
    fields.remove("time")
    let mut text = Json::object(fields).stringify()
    for digest in digests {
      if digest.1 is Some(String(value)) {
        text = text.replace_all(old=value, new=digest.0)
      }
    }
    out.push(text)
  }
  out.join("\n")
}

///|
/// Writes `files` into `dir` the way a ConfigMap volume does: into a new
/// timestamped directory `..<version>`, then points `..data` at it with an
/// atomic rename of a symlink, then removes the version it replaced, if
/// any. The visible names are symlinks into `..data`, made once.
async fn configmap_update(
  dir : String,
  version : String,
  files : Array[(String, String)],
  replaces? : String,
) -> Unit {
  for file in files {
    write(dir, "..\{version}/\{file.0}", file.1)
  }
  @fs.symlink(target="..\{version}", "\{dir}/..data_tmp")
  @fs.rename("\{dir}/..data_tmp", "\{dir}/..data")
  if replaces is Some(old) {
    @fs.rmdir("\{dir}/..\{old}", recursive=true)
  }
}

///|
/// Runs `smock render <args>` until it exits, with only `env` as its
/// environment, and renders its exit status, then what it wrote to stdout
/// and, if anything, to stderr.
async fn render(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
) -> String {
  exit_report(render_output(args, env~))
}

///|
/// The time and the seed of a rendering: the values, when `given`, or
/// `<time>` and `<seed>` when they change from run to run.
fn time_and_seed(json : Json, time_given~ : Bool, seed_given~ : Bool) -> String {
  guard json is { "time": String(time), "seed": Number(seed, ..), .. } else {
    return "no time or seed"
  }
  let time = if time_given { time } else { "<time>" }
  let seed = if seed_given { seed.to_int64().to_string() } else { "<seed>" }
  "time \{time}, seed \{seed}"
}

///|
/// Runs `smock render <args>` until it exits, with only `env` as its
/// environment, and returns its exit status, stdout and stderr.
async fn render_output(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
) -> (Int32, String, String) {
  smock_output(["render", ..args], env~)
}

///|
/// The body of the rendering `smock render` prints, without the replica
/// and the warnings, as one line of JSON.
fn rendered(json : Json) -> String {
  guard json is Object(members) else { return "not an object" }
  let out : Map[String, Json] = Map([])
  for key in ["stub", "mock", "response", "failed"] {
    out[key] = members.get(key).unwrap_or(Json::null())
  }
  Json::object(out).stringify()
}

///|
/// Renders the Stub `id` for the sample in the file `sample` through the
/// Admin API render operation, with `query` after the path, and checks the
/// response against the OpenAPI document.
async fn Smock::render(
  self : Smock,
  id : String,
  sample? : String,
  body? : String,
  query~ : String = "",
  token~ : String? = Some(test_token),
) -> AdminResponse {
  let body = match (sample, body) {
    (Some(file), _) => Some(@fs.read_file(file).text())
    (None, body) => body
  }
  let path = "/v1/stubs/\{@percent.encode(id)}/render\{query}"
  let response = self.admin("POST", path, body?, token~)
  response
}

///|
/// What `rendering` says of data: the writes the Stub would make, the
/// response and the template error, as one line of JSON.
fn writes_response_and_error(rendering : Json) -> String {
  guard rendering is Object(members) else { return "not an object" }
  let out : Map[String, Json] = Map([])
  for key in ["dataWrites", "response", "templateError"] {
    out[key] = members.get(key).unwrap_or(Json::string("absent"))
  }
  Json::object(out).stringify()
}

///|
/// Sends `meth target` with `headers` and `body` on a new connection, and
/// renders the response with `read_response`.
async fn Smock::send(
  self : Smock,
  meth : String,
  target : String,
  headers~ : Array[(String, String)] = [],
  body~ : String = "",
) -> String {
  let conn = self.connect()
  defer conn.close()
  conn.write(raw_request(meth, target, host="localhost", headers~, body~))
  read_response(conn)
}

///|
/// The example of spec #48: `GET /orders/42` answers pending until `POST
/// /orders/42/pay` moves the Scenario `checkout` to `Paid`, and paid after.
let checkout : String =
  #|{ "mocks": [{ "name": "payments" }],
  #|  "stubs": [
  #|    { "id": "order-pending", "mock": "payments",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "scenario": { "name": "checkout", "requires": "Started" },
  #|      "response": { "status": 200, "json": { "status": "pending" } } },
  #|    { "id": "pay", "mock": "payments",
  #|      "request": { "method": "POST", "path": "/orders/42/pay" },
  #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
  #|      "response": { "status": 200 } },
  #|    { "id": "order-paid", "mock": "payments",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "scenario": { "name": "checkout", "requires": "Paid" },
  #|      "response": { "status": 200, "json": { "status": "paid" } } } ] }

///|
/// `meth path` with a real HTTP client on a connection of its own, with
/// the Session `session` in its baggage when given: the status and the
/// body, if any.
async fn Smock::order(
  self : Smock,
  meth : String,
  path : String,
  session? : String,
) -> String {
  let headers : @http.Headers = Map([])
  if session is Some(session) {
    let (name, value) = baggage(session)
    headers[@http.CaseInsensitiveString(name)] = value
  }
  let client = @http.Client("http://127.0.0.1:\{self.port}", headers~)
  defer client.close()
  let response = if meth == "POST" {
    client.post(path, "")
  } else {
    client.get(path)
  }
  match client.read_all().text() {
    "" => "\{response.code}, no body"
    body => "\{response.code} \{body}"
  }
}

///|
let users : String =
  #|{
  #|  "mocks": [{ "name": "users" }],
  #|  "stubs": [
  #|    {
  #|      "id": "get-user",
  #|      "mock": "users",
  #|      "request": { "method": "GET", "path": "/users/1" },
  #|      "response": {
  #|        "status": 200,
  #|        "headers": { "Content-Type": "application/json", "X-Source": "smock" },
  #|        "body": "{\"id\":1,\"name\":\"Alice\"}"
  #|      }
  #|    }
  #|  ]
  #|}

///|
/// The `baggage` header that carries `session`, among other members.
fn baggage(session : String) -> (String, String) {
  ("baggage", "userId=alice,smock-session=\{session};ttl=60")
}

///|
/// The `baggage` header that carries `session`, when it is given; none
/// without.
fn session_headers(session : String?) -> Array[(String, String)] {
  match session {
    Some(session) => [baggage(session)]
    None => []
  }
}

///|
/// Calls the Admin API with the test token, as `session` when it is given,
/// checks the response against the document, and returns its status and
/// body.
async fn Smock::call(
  self : Smock,
  meth : String,
  path : String,
  session? : String,
  body? : String,
) -> String {
  let response = self.admin(meth, path, headers=session_headers(session), body?)
  "\{response.status} \{response.body}"
}

///|
/// `GET /users/1` on the plain port, with the Session `session` when it is
/// given: the status line, the `Smock-Near-Miss` header if any, and the
/// body.
async fn Smock::user(
  self : Smock,
  session? : String,
  meth~ : String = "GET",
) -> String {
  let response = self.send(meth, "/users/1", headers=session_headers(session))
  let lines = response.split("\n").collect()
  let near_miss = lines
    .iter()
    .filter(line => line.has_prefix("Smock-Near-Miss:"))
    .map(line => " [\{line}]")
    .collect()
    .join("")
  "\{lines[0]}\{near_miss} \{lines[lines.length() - 1]}"
}

///|
/// An Ephemeral Stub that answers `GET /users/1` with `status` and `body`.
fn ephemeral_user(status : Int32, body : String) -> String {
  "{\"request\":{\"method\":\"GET\",\"path\":\"/users/1\"},\"response\":{\"status\":\{status},\"body\":\"\{body}\"}}"
}

///|
/// When the events of `/events` in `news` are due, in milliseconds after
/// the request. The head goes out at once, before the first event, and a
/// test checks that order against the first event's time due: 1000 ms
/// leaves a slow runner room.
let news_due : Array[Int32] = [1000, 1300, 1300]

///|
/// `at <due> ms` when an event that arrived `elapsed` milliseconds after
/// the request was due `due` milliseconds after it: not before, and before
/// twice `due`. Otherwise when it arrived. The documents give when an event
/// is due, by its delay or wait, and no time by which it must arrive, so
/// the upper side is relative to that time rather than the runner's speed.
/// `due` is above 0: a frame due at once is judged by the order it comes in
/// (`H2Client::timeline`).
fn arrival(elapsed : Int64, due : Int32) -> String {
  // Timers and clocks tick in whole milliseconds.
  if elapsed >= (due - 2).to_int64() && elapsed < (2 * due).to_int64() {
    "at \{due} ms"
  } else {
    "at \{elapsed} ms, due at \{due} ms"
  }
}

///|
/// `before <first> ms` when the head arrived `elapsed` milliseconds after
/// the request, before the first event was due at `first`. Otherwise when
/// it arrived. smock "sends the status and the headers at once", then
/// waits the first event's delay (docs/definition-files/responses.md,
/// Server-Sent Events): the head comes before the first event, and on one
/// connection only the time the event is due tells the two apart. The
/// streams that use this make that time long enough to leave a slow runner
/// room, rather than loosening the bound.
fn head_arrival(elapsed : Int64, first : Int32) -> String {
  if elapsed < first.to_int64() {
    "before \{first} ms"
  } else {
    "at \{elapsed} ms, after the first event was due"
  }
}

///|
/// How many files, sockets included, the process `pid` has open.
async fn open_files(pid : Int32) -> Int32 {
  @fs.readdir("/proc/\{pid}/fd").length()
}

///|
/// `GET /users/1`, asking smock to close the connection after answering.
let get_user : String = "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

///|
/// Sends `request` on a new connection and reads one response.
async fn Smock::exchange(self : Smock, over : Over, request : String) -> String {
  let conn = self.connect(over~)
  defer conn.close()
  conn.write(request)
  read_response(conn)
}

///|
/// `/metrics`, fetched without a token and checked against the OpenAPI
/// document, read as the Prometheus text format.
async fn Smock::metrics(self : Smock) -> (String, Array[Sample]) {
  let response = self.admin("GET", "/metrics", token=None)
  (response.body, parse_prometheus(response.body))
}

///|
/// The lines of `/metrics` about the metrics whose names start with
/// `prefix`, as `metric_lines` picks them, one per line.
async fn Smock::metric(
  self : Smock,
  prefix : String,
  help~ : Bool = false,
) -> String {
  metric_lines(self.admin("GET", "/metrics").body, prefix, help~).join("\n")
}

///|
/// Whether `name` is the name of a sample of the request traffic metrics.
fn is_traffic(name : String) -> Bool {
  name.has_prefix("smock_request_duration_seconds") ||
  name == "smock_requests_total" ||
  name == "smock_unmatched_requests_total"
}

///|
/// The request traffic metrics in `/metrics`, `text`, with its `samples`:
///
/// - their `# TYPE` lines;
/// - their samples, one per line, sorted, without the latency histogram's
///   buckets and sum, whose values depend on timing;
/// - the label names of each sample name, buckets and sum included.
fn traffic(text : String, samples : Array[Sample]) -> String {
  let out = []
  for line in text.split("\n") {
    if line.strip_prefix("# TYPE ") is Some(rest) &&
      is_traffic(rest.split(" ").next().unwrap_or("").to_owned()) {
      out.push(line.to_owned())
    }
  }
  let lines = samples
    .filter(sample => {
      is_traffic(sample.name) &&
      !sample.name.has_suffix("_bucket") &&
      !sample.name.has_suffix("_sum")
    })
    .map(sample => sample.line())
  lines.sort_by((a, b) => a.lexical_compare(b))
  out.push_iter(lines.iter())
  let labels : Map[String, Array[String]] = Map([])
  for sample in samples {
    if is_traffic(sample.name) {
      let names = sample.labels.map(label => label.0).join(", ")
      match labels.get(sample.name) {
        Some(seen) if seen.contains(names) => ()
        Some(seen) => seen.push(names)
        None => labels[sample.name] = [names]
      }
    }
  }
  for name, names in labels {
    out.push("labels of \{name}: \{names.join(" | ")}")
  }
  out.join("\n")
}

///|
/// A Mock whose `/delayed` answers after a delay of 1 s, whose `/quick`
/// answers at once, and whose `/stream` sends one event at once and the
/// last one 1 s later.
let slow : String =
  #|{ "mocks": [{ "name": "slow" }],
  #|  "stubs": [
  #|    { "id": "delayed", "mock": "slow", "request": { "path": "/delayed" },
  #|      "fault": { "delay": { "fixed": 1000 } },
  #|      "response": { "status": 200, "body": "late" } },
  #|    { "id": "quick", "mock": "slow", "request": { "path": "/quick" },
  #|      "response": { "status": 200, "body": "quick" } },
  #|    { "id": "stream", "mock": "slow", "request": { "path": "/stream" },
  #|      "response": { "status": 200,
  #|        "events": [{ "data": "first" }, { "delay": 1000, "data": "last" }] } } ] }

///|
/// The example of ticket #87: `POST /login` stores the user it is sent and
/// the one stored before, and echoes both; `GET /me` reads the user back.
let who_logged_in : String =
  #|mocks:
  #|  - name: shop
  #|stubs:
  #|  - id: login
  #|    mock: shop
  #|    request: { method: POST, path: /login }
  #|    variables:
  #|      user: ${body.user}
  #|      previous: ${vars.user ?? null}
  #|    response:
  #|      status: 200
  #|      template: true
  #|      json: { user: "${vars.user}", previous: "${vars.previous}" }
  #|  - id: whoami
  #|    mock: shop
  #|    request: { method: GET, path: /me }
  #|    response:
  #|      status: 200
  #|      template: true
  #|      json: { user: "${vars.user ?? null}" }

///|
/// Sends `GET <target>` to the Mock `users` of `journal_defs`, as
/// `session`.
async fn Smock::get_user(
  self : Smock,
  target : String,
  session : String,
) -> Unit {
  let _ = self.request("GET", target, headers=[
    ("Host", "localhost"),
    baggage(session),
  ])
}

///|
/// The unmatched requests of `session`, at most `limit` of them when it is
/// given, checked against the document: the status and the body.
async fn Smock::unmatched(
  self : Smock,
  session : String,
  limit? : String,
) -> (Int32, Json) {
  let path = match limit {
    Some(limit) => "/v1/journal/unmatched?limit=\{limit}"
    None => "/v1/journal/unmatched"
  }
  let response = self.admin("GET", path, headers=[baggage(session)])
  (response.status, response.json())
}

///|
/// One line of the large body file.
let big_line : String = "0123456789abcde\n"

///|
/// The size of the large body file, 16 MiB: more than the socket buffers of
/// both ends hold on loopback, so that smock's write waits on a client that
/// reads slowly or not at all.
let big_size : Int32 = 16 * 1024 * 1024

///|
/// Mock `big`, whose Stubs answer `GET /big` with the large body file at
/// once, `GET /delayed` with it after a delay of 100 ms, `GET /half` with
/// half of it (a partial Fault), and `GET /events` with a stream of four
/// events of 16 KiB each, without delays.
let big_defs : String = {
  let data = "x".repeat(16 * 1024)
  let event = "{ \"data\": \"\{data}\" }"
  let defs =
    $|{ "mocks": [{ "name": "big" }],
    $|  "stubs": [
    $|    { "id": "big", "mock": "big", "request": { "path": "/big" },
    $|      "response": { "status": 200, "bodyFile": "big.txt" } },
    $|    { "id": "delayed", "mock": "big", "request": { "path": "/delayed" },
    $|      "response": { "status": 200, "bodyFile": "big.txt" },
    $|      "fault": { "delay": { "fixed": 100 } } },
    $|    { "id": "half", "mock": "big", "request": { "path": "/half" },
    $|      "response": { "status": 200, "bodyFile": "big.txt" },
    $|      "fault": { "connection": { "kind": "partial" } } },
    $|    { "id": "events", "mock": "big", "request": { "path": "/events" },
    $|      "response": { "status": 200,
    $|        "events": [\{event}, \{event}, \{event}, \{event}] } } ] }
  defs
}

///|
/// The text of the large body file: `big_line` over and over, `big_size`
/// bytes in all. It is built once, as the test process starts, and by
/// doubling, a few copies of memory in all: `String::repeat` appends one
/// line at a time, which took 50 to 140 ms on each call, in which no other
/// test of the package ran.
let big_text : String = {
  let mut text = big_line
  while text.length() < big_size {
    text = text + text[:big_size - text.length()].to_owned()
  }
  text
}

///|
/// The definitions directory of Mock `big`: its Definition file and its
/// large body file.
fn big_files() -> Array[(String, String)] {
  [("big.json", big_defs), ("files/big.txt", big_text)]
}
