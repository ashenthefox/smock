// Tests of the Admin API contract checker, which is in
// contract_harness_test.mbt: every reference of the OpenAPI document
// resolves, the checker rejects responses that break the document, and it
// applies `then` and `else` as `if` decides.

///|
async test "every reference in the Admin API document resolves" {
  let contract = contract.wait()
  let broken = []
  for file, json in contract.files {
    for reference in refs(json) {
      ignore(contract.resolve(file, reference)) catch {
        err => broken.push(err.to_string())
      }
    }
  }
  inspect(
    contract.files.keys().collect().join("\n"),
    content=(
      #|openapi/admin.json
      #|schema/v1/definitions.json
    ),
  )
  debug_inspect(broken, content="[]")
}

///|
async test "the contract checker rejects responses that break the document" {
  let contract = contract.wait()
  let replica = [
    ("Smock-Replica", "host-1"),
    ("Content-Type", "application/json"),
  ]
  let cases = [
    (
      "status without warnings",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":null,"mocks":[]}
        ),
      },
    ),
    (
      "status without Smock-Replica",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: [("Content-Type", "application/json")],
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":null,"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a digest that is not 12 hex digits",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"xyz","lastReload":null,"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "status without a digest",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":null,"lastReload":null,"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a 401 without WWW-Authenticate",
      "GET",
      "/v1/status",
      {
        status: 401,
        headers: replica,
        body: (
          #|{"error":"unauthorized","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "an error code the document does not list",
      "GET",
      "/nowhere",
      {
        status: 404,
        headers: replica,
        body: (
          #|{"error":"nope","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "an undocumented field",
      "GET",
      "/v1/status",
      {
        status: 401,
        headers: [..replica, ("WWW-Authenticate", "Bearer")],
        body: (
          #|{"error":"unauthorized","message":"m","warnings":[],"extra":1}
        ),
      },
    ),
    (
      "a failed reload with its errors",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"failed","errors":[{"file":"a.json","pointer":"/stubs/0","message":"m"}]},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a reload result the document does not list",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"reloaded","errors":[]},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a reload without its errors",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"swapped"},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a reload error without its pointer",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"failed","errors":[{"file":"a.json","message":"m"}]},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a passing probe",
      "GET",
      "/startupz",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"status":"ok","warnings":[]}
        ),
      },
    ),
    (
      "a passing probe with another status",
      "GET",
      "/readyz",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"status":"ready","warnings":[]}
        ),
      },
    ),
    (
      "a failing probe",
      "GET",
      "/readyz",
      {
        status: 503,
        headers: replica,
        body: (
          #|{"error":"not_ready","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a failing probe without its error code",
      "GET",
      "/startupz",
      {
        status: 503,
        headers: replica,
        body: (
          #|{"message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a passing probe with an undocumented field",
      "GET",
      "/livez",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"status":"ok","warnings":[],"uptime":1}
        ),
      },
    ),
    (
      "a reload with an undocumented field",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"unchanged","errors":[],"digest":"0123456789ab"},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-12","mock":"users","session":null,"request":{"method":"GET"},"response":{"status":503,"body":"down"}},"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub with weighted responses",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-12","mock":"users","session":null,"request":{"method":"GET"},"responses":[{"weight":9,"status":200},{"status":503,"body":"down"}]},"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub with both response and responses",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-12","mock":"users","session":null,"response":{"status":200},"responses":[{"status":503}]},"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub with a weight out of range",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-12","mock":"users","session":null,"responses":[{"weight":0,"status":503}]},"warnings":[]}
        ),
      },
    ),
    (
      "an Ephemeral Stub ID that is not eph-<n>",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-0","mock":"users","session":"s","response":{"status":200}},"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub without its Session",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-1","mock":"users","response":{"status":200}},"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with a status out of range",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":99}}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with an undocumented field",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200},"addedAt":1}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with a header array",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200,"headers":{"Content-Type":"text/plain","X-A":"1","Set-Cookie":["a=1","b=2"]}}}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with an empty header array",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200,"headers":{"Set-Cookie":[]}}}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with an array for Content-Type",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200,"headers":{"content-type":["text/plain"]}}}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with an llm reply",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","responses":[{"status":200,"llm":{"api":"openai-chat","text":"Hi","stopReason":"length","timing":{"first":{"fixed":40}}}}]}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with an llm field the Schema does not list",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200,"llm":{"api":"openai-chat","stream":true}}}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with llm beside a body",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200,"body":"Hi","llm":{"api":"openai-chat"}}}],"warnings":[]}
        ),
      },
    ),
    (
      "a deleted Ephemeral Stub with its Mock",
      "DELETE",
      "/v1/mocks/users/stubs/eph-1",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"id":"eph-1","mock":"users","warnings":[]}
        ),
      },
    ),
    (
      "an unknown Ephemeral Stub",
      "DELETE",
      "/v1/mocks/users/stubs/eph-1",
      {
        status: 404,
        headers: replica,
        body: (
          #|{"error":"unknown_stub","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a reset without the count of Journal entries",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"all","removed":{"ephemeralStubs":1,"scenarioStates":0,"variables":0,"dataBuckets":0},"warnings":[]}
        ),
      },
    ),
    (
      "a reset without the count of Scenario states",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"session","removed":{"ephemeralStubs":0,"journalEntries":2,"variables":3,"dataBuckets":0},"warnings":[]}
        ),
      },
    ),
    (
      "a reset without the count of Variables",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"mock","removed":{"ephemeralStubs":0,"journalEntries":2,"scenarioStates":1,"dataBuckets":0},"warnings":[]}
        ),
      },
    ),
    (
      "a reset with a count of Variables below 0",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"all","removed":{"ephemeralStubs":0,"journalEntries":0,"scenarioStates":0,"variables":-1,"dataBuckets":0},"warnings":[]}
        ),
      },
    ),
    (
      "a reset without the count of copies of Data buckets",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"session","removed":{"ephemeralStubs":0,"journalEntries":2,"scenarioStates":0,"variables":3},"warnings":[]}
        ),
      },
    ),
    (
      "a reset with a count of copies of Data buckets below 0",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"all","removed":{"ephemeralStubs":0,"journalEntries":0,"scenarioStates":0,"variables":0,"dataBuckets":-1},"warnings":[]}
        ),
      },
    ),
    (
      "a reset with a scope the document does not list",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"replica","removed":{"ephemeralStubs":0,"journalEntries":0,"scenarioStates":0,"variables":0,"dataBuckets":0},"warnings":[]}
        ),
      },
    ),
    (
      "a list of Variables",
      "GET",
      "/v1/mocks/shop/variables",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"variables":{"cart":{"items":[1]},"user":null},"warnings":[]}
        ),
      },
    ),
    (
      "a list of Variables with a name that is not a Variable name",
      "GET",
      "/v1/mocks/shop/variables",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"variables":{"a.b":1},"warnings":[]}
        ),
      },
    ),
    (
      "a Variable set without its value",
      "PUT",
      "/v1/mocks/shop/variables/user",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"name":"user","warnings":[]}
        ),
      },
    ),
    (
      "a Variable set to null",
      "PUT",
      "/v1/mocks/shop/variables/user",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"name":"user","value":null,"warnings":[]}
        ),
      },
    ),
    (
      "a Variable set refused by the state bound",
      "PUT",
      "/v1/mocks/shop/variables/user",
      {
        status: 507,
        headers: replica,
        body: (
          #|{"error":"state_limit_reached","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a deleted Variable with its value",
      "DELETE",
      "/v1/mocks/shop/variables/user",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"name":"user","value":"ann","warnings":[]}
        ),
      },
    ),
    (
      "an unset Variable",
      "DELETE",
      "/v1/mocks/shop/variables/user",
      {
        status: 404,
        headers: replica,
        body: (
          #|{"error":"unknown_variable","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a Journal page with an unmatched request",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":null,"session":"s","host":"users.example.com","mock":"users","viaDefault":false,"digest":"0123456789ab","request":{"method":"POST","target":"/users/1","version":"HTTP/1.1","headers":[{"name":"Host","value":"users.example.com"}],"body":{"encoding":"utf-8","data":"hi","size":2,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":{"stub":"get-user","stubSource":"file","failed":[{"condition":"method","expected":"GET","actual":["POST"]}]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":3,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry for an Ephemeral Stub",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"eph-1","stubSource":"ephemeral","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":503,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with the index of the response picked",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"eph-1","stubSource":"ephemeral","scenario":null,"responseIndex":1,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":503,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its response index",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"eph-1","stubSource":"ephemeral","scenario":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":503,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with a response index out of range",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"eph-1","stubSource":"ephemeral","scenario":null,"responseIndex":100,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":503,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with the Variables written",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/login","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"login","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":["user","previous"],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its Variables written",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/login","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"login","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with the Data buckets written",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/visit","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"visit","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":["visits","log"],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with a data write that failed",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/visit","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"visit","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":{"at":"/dataWrites/0","message":"the Data bucket \"visits\" holds a number, and \"merge\" needs an object"},"nearMiss":null,"status":500,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its Data buckets written",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/visit","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"visit","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a data write error without its message",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/visit","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"visit","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":{"at":"/dataWrites/0"},"nearMiss":null,"status":500,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry for a CRUD Stub's read",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/api/v1/orders/9999","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"orders","stubSource":"file","scenario":null,"responseIndex":null,"crud":{"op":"read","key":"9999"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry for a CRUD Stub's list",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/api/v1/orders/9999","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"orders","stubSource":"file","scenario":null,"responseIndex":null,"crud":{"op":"list","key":null},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its CRUD operation",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/api/v1/orders/9999","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"orders","stubSource":"file","scenario":null,"responseIndex":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a CRUD operation the document does not list",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/api/v1/orders/9999","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"orders","stubSource":"file","scenario":null,"responseIndex":null,"crud":{"op":"patch","key":"9999"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a CRUD operation without its key",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/api/v1/orders/9999","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"orders","stubSource":"file","scenario":null,"responseIndex":null,"crud":{"op":"list"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its Stub source",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with a Stub source the document does not list",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","stubSource":"admin","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with a Scenario move",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"payments","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/orders/42/pay","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"pay","stubSource":"file","scenario":{"name":"checkout","from":"Started","to":"Paid"},"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its Scenario move",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","stubSource":"file","responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Scenario move without the state it came from",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"payments","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/orders/42/pay","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"pay","stubSource":"file","scenario":{"name":"checkout","to":"Paid"},"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Near miss that failed a Scenario state",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":"s","host":null,"mock":"payments","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/orders/42/pay","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":{"stub":"pay","stubSource":"file","failed":[{"condition":"scenario:check out\nnow","expected":"Started","actual":["Paid"]}]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Near miss that failed a Scenario state without its name",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":"s","host":null,"mock":"payments","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/orders/42/pay","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":{"stub":"pay","stubSource":"file","failed":[{"condition":"scenario:","expected":"Started","actual":["Paid"]}]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Near miss without its Stub source",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":{"stub":"get-user","failed":[]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry for a gRPC call, with its gRPC status",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":"localhost","mock":"greeter","viaDefault":false,"digest":"0123456789ab","request":{"method":"POST","target":"/helloworld.Greeter/SayHello","version":"HTTP/2","headers":[{"name":"content-type","value":"application/grpc"},{"name":"te","value":"trailers"}],"body":{"encoding":"utf-8","data":"{\"name\":\"Tom\"}","size":10,"truncated":false}},"stub":"hello","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"grpcStatus":"OK","fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a gRPC status the document does not list",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":"localhost","mock":"greeter","viaDefault":false,"digest":"0123456789ab","request":{"method":"POST","target":"/helloworld.Greeter/SayHello","version":"HTTP/2","headers":[{"name":"content-type","value":"application/grpc"},{"name":"te","value":"trailers"}],"body":{"encoding":"utf-8","data":"{\"name\":\"Tom\"}","size":10,"truncated":false}},"stub":"hello","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"grpcStatus":"NOPE","fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a gRPC status as a number",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":"localhost","mock":"greeter","viaDefault":false,"digest":"0123456789ab","request":{"method":"POST","target":"/helloworld.Greeter/SayHello","version":"HTTP/2","headers":[{"name":"content-type","value":"application/grpc"},{"name":"te","value":"trailers"}],"body":{"encoding":"utf-8","data":"{\"name\":\"Tom\"}","size":10,"truncated":false}},"stub":"hello","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"grpcStatus":5,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a gRPC status of null",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":"localhost","mock":"greeter","viaDefault":false,"digest":"0123456789ab","request":{"method":"POST","target":"/helloworld.Greeter/SayHello","version":"HTTP/2","headers":[{"name":"content-type","value":"application/grpc"},{"name":"te","value":"trailers"}],"body":{"encoding":"utf-8","data":"{\"name\":\"Tom\"}","size":10,"truncated":false}},"stub":"hello","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"grpcStatus":null,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its sequence number",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with the sequence number 0",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":0,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its timing",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","session":null,"host":null,"mock":null,"viaDefault":false,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.0","headers":[],"body":{"encoding":"base64","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":null,"fault":"close","templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its digest",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":null,"viaDefault":false,"digest":null,"request":{"method":"GET","target":"/","version":"HTTP/1.0","headers":[],"body":{"encoding":"base64","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":null,"fault":"close","templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal page without the eviction count",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[],"more":false,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal query refused because the Journal is off",
      "POST",
      "/v1/journal/query",
      {
        status: 409,
        headers: replica,
        body: (
          #|{"error":"journal_off","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a verification that passed",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":true,"count":2,"evicted":0,"reason":null,"warnings":[]}
        ),
      },
    ),
    (
      "a verification that failed because entries were evicted",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":false,"count":0,"evicted":2,"reason":"evicted","warnings":[]}
        ),
      },
    ),
    (
      "a verification with a reason the document does not list",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":false,"count":0,"evicted":0,"reason":"bound","warnings":[]}
        ),
      },
    ),
    (
      "a verification without the eviction count",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":true,"count":1,"reason":null,"warnings":[]}
        ),
      },
    ),
    (
      "a verification with a count below 0",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":true,"count":-1,"evicted":0,"reason":null,"warnings":[]}
        ),
      },
    ),
    (
      "a verification refused because the Journal is off",
      "POST",
      "/v1/journal/verify",
      {
        status: 409,
        headers: replica,
        body: (
          #|{"error":"journal_off","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "unmatched requests, one with its Near miss and one for an unknown Host",
      "GET",
      "/v1/journal/unmatched?limit=2",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":"s","host":"users.example.com","mock":"users","viaDefault":false,"digest":"0123456789ab","request":{"method":"GET","target":"/users/x?a=b","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":{"stub":"eph-1","stubSource":"ephemeral","failed":[{"condition":"path","expected":{"pattern":"/users/[0-9]+"},"actual":["/users/x"]},{"condition":"query:a","expected":"c","actual":["b"]}]},"status":404,"fault":null,"templateError":null},{"seq":8,"receivedAt":"2026-10-13T01:02:03.005Z","durationMs":0,"session":"s","host":"nowhere.example.com","mock":null,"viaDefault":false,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":404,"fault":null,"templateError":null}],"more":true,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "unmatched requests without more",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[],"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Near miss with a condition the document does not list",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":{"stub":"get-user","stubSource":"file","failed":[{"condition":"trailer:x-id","expected":"1","actual":[]}]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "unmatched requests refused because the Journal is off",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 409,
        headers: replica,
        body: (
          #|{"error":"journal_off","message":"m","warnings":[]}
        ),
      },
    ),
  ]
  let out = []
  for case in cases {
    let (name, meth, path, response) = case
    let problems = match contract.check(meth, path, response) {
      [] => "conforms"
      problems => problems.join("; ")
    }
    out.push("\{name}: \{problems}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|status without warnings: : warnings is missing
      #|status without Smock-Replica: header Smock-Replica is missing
      #|a digest that is not 12 hex digits: /digest: "xyz" does not match ^[0-9a-f]{12}$
      #|status without a digest: /digest: null is not of type string
      #|a 401 without WWW-Authenticate: header WWW-Authenticate is missing
      #|an error code the document does not list: /error: "nope" is not one of ["unauthorized","not_found","method_not_allowed","malformed_json","invalid_request","invalid_stub","unknown_mock","unknown_stub","unknown_scenario","unknown_state","unknown_variable","unknown_bucket","invalid_data","state_limit_reached","journal_off","not_started","not_ready","bad_request","content_too_large","header_fields_too_large","not_implemented","http_version_not_supported"]
      #|an undocumented field: /extra: no value is allowed here
      #|a failed reload with its errors: conforms
      #|a reload result the document does not list: /lastReload: {"at":"2026-10-13T01:02:03.004Z","result":"reloaded","err... matches 0 of oneOf, not 1
      #|a reload without its errors: /lastReload: {"at":"2026-10-13T01:02:03.004Z","result":"swapped"} matches 0 of oneOf, not 1
      #|a reload error without its pointer: /lastReload: {"at":"2026-10-13T01:02:03.004Z","result":"failed","error... matches 0 of oneOf, not 1
      #|a passing probe: conforms
      #|a passing probe with another status: /status: "ready" is not "ok"
      #|a failing probe: conforms
      #|a failing probe without its error code: : error is missing
      #|a passing probe with an undocumented field: /uptime: no value is allowed here
      #|a reload with an undocumented field: /lastReload: {"at":"2026-10-13T01:02:03.004Z","result":"unchanged","er... matches 0 of oneOf, not 1
      #|an added Ephemeral Stub: conforms
      #|an added Ephemeral Stub with weighted responses: conforms
      #|an added Ephemeral Stub with both response and responses: /stub: {"id":"eph-12","mock":"users","session":null,"response":{... matches 2 of oneOf, not 1
      #|an added Ephemeral Stub with a weight out of range: /stub/responses/0/weight: 0 is below 1
      #|an Ephemeral Stub ID that is not eph-<n>: /stub/id: "eph-0" does not match ^eph-[1-9][0-9]*$
      #|an added Ephemeral Stub without its Session: /stub: session is missing
      #|a listed Ephemeral Stub with a status out of range: /stubs/0/response/status: 99 is below 200
      #|a listed Ephemeral Stub with an undocumented field: /stubs/0/addedAt: no value is allowed here
      #|a listed Ephemeral Stub with a header array: conforms
      #|a listed Ephemeral Stub with an empty header array: /stubs/0/response/headers/Set-Cookie: [] matches 0 of oneOf, not 1
      #|a listed Ephemeral Stub with an array for Content-Type: /stubs/0/response/headers/content-type: ["text/plain"] is not of type string
      #|a listed Ephemeral Stub with an llm reply: conforms
      #|a listed Ephemeral Stub with an llm field the Schema does not list: /stubs/0/response/llm/stream: no value is allowed here
      #|a listed Ephemeral Stub with llm beside a body: /stubs/0/response/llm: no value is allowed here
      #|a deleted Ephemeral Stub with its Mock: /mock: no value is allowed here
      #|an unknown Ephemeral Stub: conforms
      #|a reset without the count of Journal entries: /removed: journalEntries is missing
      #|a reset without the count of Scenario states: /removed: scenarioStates is missing
      #|a reset without the count of Variables: /removed: variables is missing
      #|a reset with a count of Variables below 0: /removed/variables: -1 is below 0
      #|a reset without the count of copies of Data buckets: /removed: dataBuckets is missing
      #|a reset with a count of copies of Data buckets below 0: /removed/dataBuckets: -1 is below 0
      #|a reset with a scope the document does not list: /scope: "replica" is not one of ["session","mock","all"]
      #|a list of Variables: conforms
      #|a list of Variables with a name that is not a Variable name: /variables (name a.b): "a.b" does not match ^[A-Za-z0-9_-]{1,128}$
      #|a Variable set without its value: : value is missing
      #|a Variable set to null: conforms
      #|a Variable set refused by the state bound: conforms
      #|a deleted Variable with its value: /value: no value is allowed here
      #|an unset Variable: conforms
      #|a Journal page with an unmatched request: conforms
      #|a Journal entry for an Ephemeral Stub: conforms
      #|a Journal entry with the index of the response picked: conforms
      #|a Journal entry without its response index: /entries/0: responseIndex is missing
      #|a Journal entry with a response index out of range: /entries/0/responseIndex: 100 is above 99
      #|a Journal entry with the Variables written: conforms
      #|a Journal entry without its Variables written: /entries/0: variablesWritten is missing
      #|a Journal entry with the Data buckets written: conforms
      #|a Journal entry with a data write that failed: conforms
      #|a Journal entry without its Data buckets written: /entries/0: dataWritten is missing
      #|a data write error without its message: /entries/0/dataError: {"at":"/dataWrites/0"} matches 0 of oneOf, not 1
      #|a Journal entry for a CRUD Stub's read: conforms
      #|a Journal entry for a CRUD Stub's list: conforms
      #|a Journal entry without its CRUD operation: /entries/0: crud is missing
      #|a CRUD operation the document does not list: /entries/0/crud: {"op":"patch","key":"9999"} matches 0 of oneOf, not 1
      #|a CRUD operation without its key: /entries/0/crud: {"op":"list"} matches 0 of oneOf, not 1
      #|a Journal entry without its Stub source: /entries/0: stubSource is missing
      #|a Journal entry with a Stub source the document does not list: /entries/0/stubSource: "admin" is not one of ["file","ephemeral",null]
      #|a Journal entry with a Scenario move: conforms
      #|a Journal entry without its Scenario move: /entries/0: scenario is missing
      #|a Scenario move without the state it came from: /entries/0/scenario: {"name":"checkout","to":"Paid"} matches 0 of oneOf, not 1
      #|a Near miss that failed a Scenario state: conforms
      #|a Near miss that failed a Scenario state without its name: /entries/0/nearMiss: {"stub":"pay","stubSource":"file","failed":[{"condition":... matches 0 of oneOf, not 1
      #|a Near miss without its Stub source: /entries/0/nearMiss: {"stub":"get-user","failed":[]} matches 0 of oneOf, not 1
      #|a Journal entry for a gRPC call, with its gRPC status: conforms
      #|a gRPC status the document does not list: /entries/0/grpcStatus: "NOPE" is not one of ["OK","CANCELLED","UNKNOWN","INVALID_ARGUMENT","DEADLINE_EXCEEDED","NOT_FOUND","ALREADY_EXISTS","PERMISSION_DENIED","RESOURCE_EXHAUSTED","FAILED_PRECONDITION","ABORTED","OUT_OF_RANGE","UNIMPLEMENTED","INTERNAL","UNAVAILABLE","DATA_LOSS","UNAUTHENTICATED"]
      #|a gRPC status as a number: /entries/0/grpcStatus: 5 is not one of ["OK","CANCELLED","UNKNOWN","INVALID_ARGUMENT","DEADLINE_EXCEEDED","NOT_FOUND","ALREADY_EXISTS","PERMISSION_DENIED","RESOURCE_EXHAUSTED","FAILED_PRECONDITION","ABORTED","OUT_OF_RANGE","UNIMPLEMENTED","INTERNAL","UNAVAILABLE","DATA_LOSS","UNAUTHENTICATED"]
      #|a gRPC status of null: /entries/0/grpcStatus: null is not one of ["OK","CANCELLED","UNKNOWN","INVALID_ARGUMENT","DEADLINE_EXCEEDED","NOT_FOUND","ALREADY_EXISTS","PERMISSION_DENIED","RESOURCE_EXHAUSTED","FAILED_PRECONDITION","ABORTED","OUT_OF_RANGE","UNIMPLEMENTED","INTERNAL","UNAVAILABLE","DATA_LOSS","UNAUTHENTICATED"]
      #|a Journal entry without its sequence number: /entries/0: seq is missing
      #|a Journal entry with the sequence number 0: /entries/0/seq: 0 is below 1
      #|a Journal entry without its timing: /entries/0: durationMs is missing
      #|a Journal entry without its digest: /entries/0/digest: null is not of type string
      #|a Journal page without the eviction count: : evicted is missing
      #|a Journal query refused because the Journal is off: conforms
      #|a verification that passed: conforms
      #|a verification that failed because entries were evicted: conforms
      #|a verification with a reason the document does not list: /reason: "bound" is not one of ["count","evicted",null]
      #|a verification without the eviction count: : evicted is missing
      #|a verification with a count below 0: /count: -1 is below 0
      #|a verification refused because the Journal is off: conforms
      #|unmatched requests, one with its Near miss and one for an unknown Host: conforms
      #|unmatched requests without more: : more is missing
      #|a Near miss with a condition the document does not list: /entries/0/nearMiss: {"stub":"get-user","stubSource":"file","failed":[{"condit... matches 0 of oneOf, not 1
      #|unmatched requests refused because the Journal is off: conforms
    ),
  )
}

///|
test "the contract checker applies then where if holds and else where it does not, as the Schema narrows an llm's stop reason by its api" {
  let checker = Contract::{ files: Map([]), }
  let schema : Json = {
    "type": "object",
    "properties": {
      "api": { "enum": ["openai-chat", "anthropic-messages"] },
      "stopReason": { "enum": ["stop", "end_turn"] },
    },
    "allOf": [
      {
        "if": {
          "properties": { "api": { "const": "openai-chat" } },
          "required": ["api"],
        },
        "then": { "properties": { "stopReason": { "enum": ["stop"] } } },
        "else": { "properties": { "stopReason": { "enum": ["end_turn"] } } },
      },
    ],
  }
  let values : Array[Json] = [
    { "api": "openai-chat", "stopReason": "stop" },
    { "api": "openai-chat", "stopReason": "end_turn" },
    { "api": "anthropic-messages", "stopReason": "end_turn" },
    { "api": "anthropic-messages", "stopReason": "stop" },
    { "stopReason": "stop" },
  ]
  let out = []
  for value in values {
    let problems = []
    checker.validate({ file: "llm.json", json: schema, }, value, "", problems)
    let verdict = if problems.is_empty() {
      "conforms"
    } else {
      problems.join("; ")
    }
    out.push("\{value.stringify()}: \{verdict}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"api":"openai-chat","stopReason":"stop"}: conforms
      #|{"api":"openai-chat","stopReason":"end_turn"}: /stopReason: "end_turn" is not one of ["stop"]
      #|{"api":"anthropic-messages","stopReason":"end_turn"}: conforms
      #|{"api":"anthropic-messages","stopReason":"stop"}: /stopReason: "stop" is not one of ["end_turn"]
      #|{"stopReason":"stop"}: /stopReason: "stop" is not one of ["end_turn"]
    ),
  )
}
