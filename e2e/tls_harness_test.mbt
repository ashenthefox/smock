// Helpers of the TLS tests: certificate pairs in directories of their own,
// the Mocks that use them, smock's log entries about certificates, and
// `openssl`, whose s_client shows which certificate smock presents and
// which protocol ALPN selects.

///|
/// Whether a log line is about a TLS certificate.
fn is_certificate_entry(line : String) -> Bool {
  let entry = @json.parse(line) catch { _ => return false }
  entry is Object(fields) &&
  fields.get("msg") is Some(String(msg)) &&
  msg.contains("TLS certificate")
}

///|
/// Waits until smock has logged `count` entries about TLS certificates in
/// all, at most `within` milliseconds, and returns them as `log_entries`
/// shows them.
async fn Smock::certificate_entries(
  self : Smock,
  count : Int32,
  within~ : Int32 = reload_patience_ms,
) -> String {
  let logged = wait_for(within, () => {
    let lines = self.logs.filter(is_certificate_entry)
    if lines.length() >= count {
      Some(log_entries(lines))
    } else {
      None
    }
  })
  guard logged is Some(logged) else {
    fail(
      "fewer than \{count} entries about TLS certificates in time:\n\{self.logs.join("\n")}",
    )
  }
  logged
}

///|
/// Runs `f` with a new temporary directory that holds `tls.crt` and
/// `tls.key`: `chain` and `key`.
async fn with_pair(
  chain : String,
  key : String,
  f : async (String) -> Unit,
) -> Unit {
  with_definitions([("tls.crt", chain + "\n"), ("tls.key", key + "\n")], f)
}

///|
/// The value of `--tls-mock-certs` that gives each Mock in `pairs` the
/// `tls.crt` and `tls.key` of its directory.
fn mock_certs(pairs : Array[(String, String)]) -> String {
  let mapping : Map[String, Json] = Map([])
  for pair in pairs {
    let (mock, dir) = pair
    mapping[mock] = {
      "certFile": Json::string("\{dir}/tls.crt"),
      "keyFile": Json::string("\{dir}/tls.key"),
    }
  }
  Json::object(mapping).stringify()
}

///|
/// Creates a temporary directory, runs `f` with its path and removes it.
async fn with_scratch(f : async (String) -> Unit) -> Unit {
  let dir = @fs.tmpdir(prefix="smock-e2e-scratch-")
  defer @fs.rmdir(dir, recursive=true)
  f(dir)
}

///|
/// The certificate the TLS port presents to a new connection, as a client
/// that does not verify it sees it.
struct Presented {
  /// A file that holds it in PEM.
  file : String
  /// Its SHA-256 fingerprint, as `openssl x509 -fingerprint -sha256`
  /// prints it.
  fingerprint : String
  /// Its subject alternative names, as `openssl x509` prints them.
  names : String
  subject : String
  issuer : String
}

///|
/// Runs `openssl <args>` and returns its exit status and its standard
/// output.
async fn run_openssl(args : Array[String], stdin? : String) -> (Int32, String) {
  let result = @async.with_timeout_opt(patience_ms, () => {
    match stdin {
      Some(path) =>
        @process.collect_output(
          "openssl",
          args,
          stdin=@process.redirect_from_file(path),
        )
      None => @process.collect_output("openssl", args)
    }
  })
  guard result is Some((status, stdout, _)) else {
    fail("openssl \{args.join(" ")} did not exit in time")
  }
  (status, stdout.text())
}

///|
/// The first line of `text` that starts with `prefix`, without the prefix.
fn line_after(text : String, prefix : String) -> String {
  for line in text.split("\n") {
    let line = line.trim(chars=" \r")
    if line.has_prefix(prefix) {
      return line[prefix.length():].to_owned()
    }
  }
  "(none)"
}

///|
/// The line of `text` that follows the first line that contains `title`.
fn line_following(text : String, title : String) -> String {
  let lines = text.split("\n").collect()
  for i, line in lines {
    if line.contains(title) && i + 1 < lines.length() {
      return lines[i + 1].trim(chars=" \r").to_owned()
    }
  }
  "(no \{title})"
}

///|
/// Reads the certificate the TLS port presents to a new connection, as a
/// client that does not verify it, and writes it to a new file in `dir`.
async fn Smock::presented_certificate(self : Smock, dir : String) -> Presented {
  write(dir, "empty.txt", "")
  let (_, output) = run_openssl(
    ["s_client", "-connect", "127.0.0.1:\{self.tls_port}"],
    stdin="\{dir}/empty.txt",
  )
  let end = "-----END CERTIFICATE-----"
  guard output.find("-----BEGIN CERTIFICATE-----") is Some(start) &&
    output.find(end) is Some(stop) else {
    fail("openssl s_client printed no certificate:\n\{output}")
  }
  let name = "presented-\{@fs.readdir(dir).length()}.pem"
  write(dir, name, output[start:stop + end.length()].to_owned() + "\n")
  let file = "\{dir}/\{name}"
  // The fingerprint has a call of its own: OpenSSL 4.1.0 prints a wrong one
  // when `-ext` is in the same call.
  let (_, digest) = run_openssl([
    "x509", "-in", file, "-noout", "-fingerprint", "-sha256",
  ])
  // RFC 2253 prints names the same in every OpenSSL version: OpenSSL 3.0's
  // default writes `CN = name`, later versions `CN=name`.
  let (_, text) = run_openssl([
    "x509", "-in", file, "-noout", "-subject", "-issuer", "-nameopt", "RFC2253",
    "-ext", "subjectAltName",
  ])
  {
    file,
    fingerprint: line_after(digest, "sha256 Fingerprint="),
    names: line_following(text, "X509v3 Subject Alternative Name"),
    subject: line_after(text, "subject="),
    issuer: line_after(text, "issuer="),
  }
}

///|
/// A Definition file that declares a Mock for each (name, Host) pair in
/// `mocks`, with a Stub `GET /x` that answers with `status`.
fn mocks_with_stubs(
  mocks : Array[(String, String)],
  status~ : Int32 = 200,
) -> String {
  let declared = mocks.map(mock => {
    "{ \"name\": \"\{mock.0}\", \"hosts\": [\"\{mock.1}\"] }"
  })
  let stubs = mocks.map(mock => {
    (
      $|{ "id": "\{mock.0}-x", "mock": "\{mock.0}",
      $|  "request": { "method": "GET", "path": "/x" },
      $|  "response": { "status": \{status} } }
    )
  })
  "{ \"mocks\": [\{declared.join(", ")}], \"stubs\": [\{stubs.join(", ")}] }"
}

///|
/// `text` with the temporary directory of `certs` shown as `$CERTS`.
fn hide_dir(text : String, certs : Certificates) -> String {
  text.replace_all(old=certs.dir, new="$CERTS")
}

///|
/// Runs `openssl s_client` against the TLS port with `options`, trusting
/// only the PEM certificates in the file `ca` (by default the test root CA
/// of `certs`), sends `request` once the handshake is done, and returns its
/// exit status and, for each group of prefixes in `show`, the first line it
/// printed that starts with one of them. By default these are what ALPN
/// selected, the certificate verification result and the response's status
/// line. The request goes through a file in `certs.dir`. The output is read
/// as UTF-8 with any other octets replaced: over `h2`, s_client prints the
/// server's frames, whose SETTINGS values need not be UTF-8.
async fn Smock::s_client(
  self : Smock,
  certs : Certificates,
  options : Array[String],
  request : String,
  ca~ : String = certs.ca,
  show~ : Array[Array[String]] = [
    ["ALPN protocol:", "No ALPN negotiated"],
    ["Verify return code:"],
    ["HTTP/"],
  ],
) -> String {
  write(certs.dir, "request.txt", request)
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_output(
      "openssl",
      [
        "s_client",
        "-connect",
        "127.0.0.1:\{self.tls_port}",
        "-CAfile",
        ca,
        "-verify_return_error",
        "-ign_eof",
        ..options,
      ],
      stdin=@process.redirect_from_file("\{certs.dir}/request.txt"),
    )
  })
  guard result is Some((status, stdout, _)) else {
    fail("openssl s_client did not exit in time")
  }
  let lines = @utf8.decode_lossy(stdout.binary())
    .split("\n")
    .map(line => line.trim_end(chars="\r"))
    .collect()
  let first = (prefixes : Array[String]) => {
    lines
    .iter()
    .filter(line => prefixes.iter().any(prefix => line.has_prefix(prefix)))
    .map(line => line.to_owned())
    .collect()
    .get(0)
    .unwrap_or("(none of \{prefixes.join(", ")})")
  }
  ["status \{status}", ..show.map(first)].join("\n")
}

///|
/// Opens a TLS connection to `server_name`, trusting only the PEM
/// certificates in `trusted`, that offers `offer` by ALPN, then sends
/// `GET path` for that Host over the protocol ALPN selected: HTTP/2 for
/// `h2`, else HTTP/1.1. Returns the protocol selected and the response's
/// status line, or why the handshake failed: the alert smock sent, named
/// as in RFC 8446, section 6, or else OpenSSL's reason.
async fn Smock::alpn_offer(
  self : Smock,
  offer : Array[String],
  server_name~ : String = "localhost",
  trusted~ : String = @testcerts.root_ca,
  path~ : String = "/users/1",
) -> String {
  let tls = self.tls(alpn=offer, server_name~, trusted~) catch {
    HandshakeAlert(120) =>
      return "handshake failed: smock sent alert no_application_protocol"
    HandshakeAlert(alert) =>
      return "handshake failed: smock sent alert \{alert}"
    @openssl.Failed(reason) => return "handshake failed: \{reason}"
    err => raise err
  }
  let protocol = tls.protocol()
  let status = if protocol == "h2" {
    let client = H2Client::over(Encrypted(tls))
    defer client.close()
    "HTTP/2 \{client.request("GET", path, authority=server_name).status}"
  } else {
    defer tls.close()
    tls.write(
      @utf8.encode(
        "GET \{path} HTTP/1.1\r\nHost: \{server_name}\r\nConnection: close\r\n\r\n",
      ),
    )
    status_line(@utf8.decode_lossy(tls.read_all()))
    .trim_end(chars="\r")
    .to_owned()
  }
  "ALPN \{protocol}, \{status}"
}

///|
/// Two Mocks with Hosts, each with a Stub `GET /x` that answers with its
/// name on a line of its own.
let users_and_orders : Array[(String, String)] = [
  (
    "mocks.json",
    (
      #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"] },
      #|            { "name": "orders", "hosts": ["orders.example.com"] }],
      #|  "stubs": [{ "id": "users-x", "mock": "users",
      #|              "request": { "method": "GET", "path": "/x" },
      #|              "response": { "status": 200, "body": "from users\n" } },
      #|            { "id": "orders-x", "mock": "orders",
      #|              "request": { "method": "GET", "path": "/x" },
      #|              "response": { "status": 200, "body": "from orders\n" } }] }
    ),
  ),
]
