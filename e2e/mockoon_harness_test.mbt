// Helpers of the tests of the mockoon log format: the Mocks they serve,
// the lines smock writes, picked out and with what varies masked, and how
// the Journal says each request ended.

///|
/// `line` with the value of its `timestamp`, wherever the key stands, shown
/// as `<timestamp>` when it has the form `YYYY-MM-DDTHH:mm:ss.sssZ`, and each
/// text of `replace` written as the placeholder it comes with. A value of
/// any other form stays, so that it shows.
fn masked_line(
  line : String,
  replace~ : Array[(String, String)] = [],
) -> String {
  let key = ",\"timestamp\":\""
  let mut line = line
  if line.find(key) is Some(i) {
    let start = i + key.length()
    let end = start + "0000-00-00T00:00:00.000Z".length()
    if end <= line.length() && time_has_form(line[start:end].to_owned()) {
      line = "\{line[:start]}<timestamp>\{line[end:]}"
    }
  }
  for pair in replace {
    let (text, placeholder) = pair
    line = line.replace_all(old=text, new=placeholder)
  }
  line
}

///|
/// Whether `time` has the form `YYYY-MM-DDTHH:mm:ss.sssZ`.
fn time_has_form(time : String) -> Bool {
  let form = "0000-00-00T00:00:00.000Z"
  guard time.length() == form.length() else { return false }
  for j, c in form {
    let ok = if c == '0' {
      time[j] >= '0' && time[j] <= '9'
    } else {
      time[j] == c.to_int().to_uint16()
    }
    if !ok {
      return false
    }
  }
  true
}

///|
/// The Mock `shop`, with the Journal on or off for it as `journal` says,
/// and Stubs whose content fails: `create-order`, at `POST /orders`, whose
/// template reads `body.customer.name`; `visit`, at `POST /visits`, whose
/// data write merges into a number; `count`, at `POST /count`, whose
/// Variable's value reads `body.count`; `slow-order` and `reset-order`, at
/// `POST /slow-orders` and `POST /reset-orders`, which fail as
/// `create-order` does, after a delay of 1 s and with a reset Fault. Then
/// Stubs whose answers are not failures of their content: `big`, at
/// `POST /big`, whose Variable takes the whole body, and the CRUD Stub
/// `items`, at `/items`.
fn failing_shop(journal~ : Bool = true) -> Array[(String, String)] {
  [
    (
      "shop.yaml",
      (
        $|mocks:
        $|  - { name: shop, journal: \{journal} }
        $|data:
        $|  - { mock: shop, name: visits, json: 0 }
        $|  - { mock: shop, name: items, key: id, json: [] }
        $|stubs:
        $|  - id: create-order
        $|    mock: shop
        $|    request: { method: POST, path: /orders }
        $|    response: { status: 201, template: true, json: { name: "${body.customer.name}" } }
        $|  - id: visit
        $|    mock: shop
        $|    request: { method: POST, path: /visits }
        $|    dataWrites: [{ op: merge, bucket: visits, value: { last: now } }]
        $|    response: { status: 204 }
        $|  - id: count
        $|    mock: shop
        $|    request: { method: POST, path: /count }
        $|    variables: { count: "${body.count}" }
        $|    response: { status: 204 }
        $|  - id: slow-order
        $|    mock: shop
        $|    request: { method: POST, path: /slow-orders }
        $|    response: { status: 201, template: true, json: { name: "${body.customer.name}" } }
        $|    fault: { delay: { fixed: 1000 } }
        $|  - id: reset-order
        $|    mock: shop
        $|    request: { method: POST, path: /reset-orders }
        $|    response: { status: 201, template: true, json: { name: "${body.customer.name}" } }
        $|    fault: { connection: { kind: reset } }
        $|  - id: big
        $|    mock: shop
        $|    request: { method: POST, path: /big }
        $|    variables: { big: "${body}" }
        $|    response: { status: 204 }
        $|  - id: items
        $|    mock: shop
        $|    crud: { bucket: items, path: /items }
      ),
    ),
  ]
}

///|
/// The error lines and the Transaction recorded lines among `lines`, in
/// order.
fn served_lines(lines : Array[String]) -> Array[String] {
  lines.filter(line => {
    line.contains("\"message\":\"Transaction recorded\"") ||
    line.contains("\"message\":\"Error while serving the content: ")
  })
}

///|
/// Two Mocks, neither of them the Default Mock: `users`, at the Hosts
/// `localhost` and `127.0.0.1`, with a Stub for `GET /users/1`, and
/// `orders`, at `orders.example.com`. With `default=true`, `users` is the
/// Default Mock.
fn mockoon_mocks(default~ : Bool = false) -> Array[(String, String)] {
  [
    (
      "users.json",
      (
        $|{ "mocks": [
        $|    { "name": "users", "hosts": ["localhost", "127.0.0.1"], "default": \{default} },
        $|    { "name": "orders", "hosts": ["orders.example.com"] }],
        $|  "stubs": [{ "id": "get-user", "mock": "users",
        $|    "request": { "method": "GET", "path": "/users/1" },
        $|    "response": { "status": 200, "body": "Alice" } }] }
      ),
    ),
  ]
}

///|
/// `line` with the value of its `timestamp`, its last key, shown as
/// `<timestamp>` when it has the form `YYYY-MM-DDTHH:mm:ss.sssZ`. A value of
/// any other form stays, so that it shows.
fn mask_timestamp(line : String) -> String {
  let key = ",\"timestamp\":\""
  guard line.rev_find(key) is Some(i) else { return line }
  let start = i + key.length()
  let rest = line[start:]
  let form = "0000-00-00T00:00:00.000Z\"}"
  guard rest.length() == form.length() else { return line }
  for j, c in form {
    let ok = if c == '0' {
      rest[j] >= '0' && rest[j] <= '9'
    } else {
      rest[j] == c.to_int().to_uint16()
    }
    if !ok {
      return line
    }
  }
  "\{line[:start]}<timestamp>\"}"
}

///|
/// `lines` with their timestamps masked, one per line.
fn masked_lines(lines : Array[String]) -> String {
  lines.map(mask_timestamp).join("\n")
}

///|
/// The Transaction recorded lines among `lines`.
fn transactions(lines : Array[String]) -> Array[String] {
  lines.filter(line => line.contains("\"message\":\"Transaction recorded\""))
}

///|
/// Waits until smock has written `count` Transaction recorded lines to
/// stdout, while it runs, and returns them all.
async fn Smock::transaction_lines(self : Smock, count : Int32) -> Array[String] {
  let written = @async.with_timeout_opt(patience_ms, () => {
    while transactions(self.stdout).length() < count {
      @async.sleep(10)
    }
  })
  guard written is Some(_) else {
    fail(
      "smock wrote \{transactions(self.stdout).length()} of \{count} Transaction recorded lines in time:\n\{self.stdout.join("\n")}",
    )
  }
  transactions(self.stdout)
}

///|
/// When smock wrote `line`, by its `timestamp`, in milliseconds since the
/// Unix epoch, as `@async.now()` gives times.
fn written_at(line : String) -> Int64 raise {
  guard @json.parse(line) is Object(fields) &&
    fields.get("timestamp") is Some(String(timestamp)) &&
    @log.parse_time(timestamp) is Some(at) else {
    fail("no timestamp in \{line}")
  }
  at
}

///|
/// How the Journal says each request it holds ended, oldest first, one per
/// line: `<method> <target>: <status>`, or `<method> <target>: fault
/// <name>` for a reset or a close Fault.
async fn Smock::journal_endings(self : Smock) -> String {
  guard self.journal() is (200, Object({ "entries": Array(entries), .. })) else {
    fail("no Journal")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object(
            { "method": String(meth), "target": String(target), .. }
          ),
          "status": status,
          "fault": fault,
          ..
        }
      ) else {
      fail("unexpected entry: \{entry.stringify()}")
    }
    let ended = match (status, fault) {
      (Number(status, ..), _) => status.to_int().to_string()
      (_, String(fault)) => "fault \{fault}"
      _ => "neither a status nor a Fault"
    }
    out.push("\{meth} \{target}: \{ended}")
  }
  out.join("\n")
}

///|
/// The `message` of the log line `line`, or `line` itself when it has none.
fn message_of(line : String) -> String {
  let entry = @json.parse(line) catch { _ => return line }
  match entry {
    Object({ "message": String(message), .. }) => message
    _ => line
  }
}

///|
/// The ports of `smock` as placeholders, for `masked_line`.
fn port_placeholders(smock : Smock) -> Array[(String, String)] {
  [
    ("0.0.0.0:\{smock.port}\"", "0.0.0.0:<plain port>\""),
    ("0.0.0.0:\{smock.tls_port}\"", "0.0.0.0:<TLS port>\""),
    ("on port \{smock.port}\"", "on port <plain port>\""),
  ]
}
