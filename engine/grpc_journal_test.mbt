// Seam 1 tests of a gRPC call's status in the Journal: the plan of a call
// carries its gRPC part, whose status the entry records as `grpcStatus`,
// and the entry's final-status method sets the status the call really got
// before the entry is committed. An HTTP request's plan and entry have
// none. The set is gRPC's helloworld.proto (greeter_set_test.mbt), and the
// Stubs are those of grpc_calls_test.mbt.

///|
/// The members of the Admin JSON of the Journal entry of `outcome` that
/// tell how its request was answered: `stub`, `status`, `grpcStatus` when
/// it has one, and `templateError`.
fn answer_members(outcome : @engine.Outcome) -> Json {
  guard outcome.journal is Some(entry) && entry.to_json() is Object(members) else {
    abort("no entry")
  }
  let shown = Map([])
  for name in ["stub", "status", "grpcStatus", "templateError"] {
    if members.get(name) is Some(value) {
      shown[name] = value
    }
  }
  Json::object(shown)
}

///|
test "a call answered by a gRPC Stub has a plan with the gRPC status OK, which its entry records as grpcStatus; an HTTP request's has none" {
  let h = harness(
    [("greeter.yaml", greeter_calls)],
    body_files=greeter_body_files(),
  )
  let call = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  inspect(grpc_part(call), content="OK")
  json_inspect(answer_members(call), content={
    "stub": "hello",
    "status": 200,
    "grpcStatus": "OK",
    "templateError": null,
  })
  let http = h.send(
    "POST",
    "/helloworld.Greeter/SayHello",
    body="{\"name\":\"Tom\"}",
  )
  inspect(grpc_part(http), content="none")
  json_inspect(answer_members(http), content={
    "stub": "any-post",
    "status": 200,
    "templateError": null,
  })
}

///|
test "the final-status method sets the gRPC status a call really got, and keeps its HTTP status" {
  let h = harness(
    [
      (
        "greeter.yaml",
        (
          #|mocks:
          #|  - name: greeter
          #|    grpc: { descriptorSet: greeter.binpb }
          #|stubs:
          #|  - id: fails
          #|    mock: greeter
          #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: fails } }
          #|    response: { template: true, json: { message: "${body.missing.name}" } }
          #|  - id: hello
          #|    mock: greeter
          #|    request: { path: /helloworld.Greeter/SayHello }
          #|    response: { json: { message: Hello } }
        ),
      ),
    ],
    body_files=greeter_body_files(),
  )
  // A template that fails: smock answers in its own way, INTERNAL, which
  // the plan's gRPC part carries and the entry records, with the HTTP
  // status 200.
  let failed = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
    headers=[("x-tenant", "fails")],
  )
  inspect(
    grpc_part(failed),
    content=(
      #|INTERNAL
      #|grpc-message: template failed
    ),
  )
  json_inspect(answer_members(failed), content={
    "stub": "fails",
    "status": 200,
    "grpcStatus": "INTERNAL",
    "templateError": {
      "at": "/response/json/message",
      "message": "body.missing.name is missing",
    },
  })
  // A delay may hold that answer back past the call's deadline, which ends
  // it otherwise: the template error stays.
  guard failed.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(DeadlineExceeded)
  json_inspect(answer_members(failed), content={
    "stub": "fails",
    "status": 200,
    "grpcStatus": "DEADLINE_EXCEEDED",
    "templateError": {
      "at": "/response/json/message",
      "message": "body.missing.name is missing",
    },
  })
  // A reply planned as OK may end otherwise, as at a deadline.
  let call = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  guard call.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(DeadlineExceeded)
  json_inspect(answer_members(call), content={
    "stub": "hello",
    "status": 200,
    "grpcStatus": "DEADLINE_EXCEEDED",
    "templateError": null,
  })
}

///|
test "a template error the final-status method sets counts two bytes for each character of its text toward the entry's bytes, in place of the one the entry had" {
  let h = harness(
    [("greeter.yaml", greeter_calls)],
    body_files=greeter_body_files(),
  )
  let tom = () => {
    h.call("/helloworld.Greeter/SayHello", "{\"name\":\"Tom\"}", octets=10)
  }
  let committed = (outcome : @engine.Outcome) => {
    guard outcome.journal is Some(entry) else { abort("no entry") }
    let before = h.engine.journal_stats().bytes
    h.engine.commit(entry)
    h.engine.journal_stats().bytes - before
  }
  let plain = committed(tom())
  // `/response/json/mesage` has 21 characters and `is not a field of
  // helloworld.HelloReply` 39: 60 in all, two bytes each.
  let failed = tom()
  guard failed.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(Internal, template_error={
    at: "/response/json/mesage",
    message: "is not a field of helloworld.HelloReply",
  })
  inspect(committed(failed) - plain, content="120")
  json_inspect(answer_members(failed), content={
    "stub": "hello",
    "status": 200,
    "grpcStatus": "INTERNAL",
    "templateError": {
      "at": "/response/json/mesage",
      "message": "is not a field of helloworld.HelloReply",
    },
  })
  // A second error replaces the first, and only its text counts: `/x`
  // and `y`, 3 characters.
  let twice = tom()
  guard twice.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(Internal, template_error={
    at: "/response/json/mesage",
    message: "is not a field of helloworld.HelloReply",
  })
  entry.set_grpc_status(Internal, template_error={ at: "/x", message: "y", })
  inspect(committed(twice) - plain, content="6")
  // Without one, the entry keeps its own.
  let kept = tom()
  guard kept.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(Internal, template_error={ at: "/x", message: "y", })
  entry.set_grpc_status(Unavailable)
  inspect(committed(kept) - plain, content="6")
  json_inspect(answer_members(kept), content={
    "stub": "hello",
    "status": 200,
    "grpcStatus": "UNAVAILABLE",
    "templateError": { "at": "/x", "message": "y" },
  })
}

///|
/// The Mock `greeter` with the set, and a gRPC Stub on SayHello with a
/// delay of 3000 ms and the connection Fault `kind`.
fn delayed_fault(kind : String) -> String {
  (
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: faulty
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json: { message: Hello } }
  ) +
  "\n    fault: { delay: { fixed: 3000 }, connection: { kind: \{kind} } }"
}

///|
/// The members of the Admin JSON of the Journal entry of `outcome` that
/// tell how a connection Fault ended its call, `status`, `grpcStatus` when
/// it has one, and `fault`, and the connection Fault of its plan, as
/// `plan`.
fn fault_members(outcome : @engine.Outcome) -> Json {
  guard outcome.journal is Some(entry) && entry.to_json() is Object(members) else {
    abort("no entry")
  }
  let shown = Map([])
  for name in ["status", "grpcStatus", "fault"] {
    if members.get(name) is Some(value) {
      shown[name] = value
    }
  }
  shown["plan"] = match outcome.plan.fault {
    Some(kind) => Json::string(kind.name())
    None => Json::null()
  }
  Json::object(shown)
}

///|
test "a call whose plan has a reset or close Fault has no status and no gRPC status in its entry, while a partial one keeps both; without its Fault, as when the call's deadline cuts its delay short, the plan and the entry have none, and the entry has the plan's status and gRPC status" {
  let shown : Array[Json] = []
  for kind in ["reset", "close", "partial"] {
    let h = harness(
      [("greeter.yaml", delayed_fault(kind))],
      body_files=greeter_body_files(),
    )
    let call = h.call(
      "/helloworld.Greeter/SayHello",
      "{\"name\":\"Tom\"}",
      octets=10,
    )
    let planned = fault_members(call)
    let without = fault_members(call.without_fault())
    shown.push(
      Json::object({
        "kind": Json::string(kind),
        "planned": planned,
        "without": without,
      }),
    )
  }
  // Without a Fault, the outcome stays as it is.
  let h = harness(
    [("greeter.yaml", greeter_calls)],
    body_files=greeter_body_files(),
  )
  let call = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  inspect(physical_equal(call.without_fault().plan, call.plan), content="true")
  json_inspect(shown, content=[
    {
      "kind": "reset",
      "planned": { "status": null, "fault": "reset", "plan": "reset" },
      "without": {
        "status": 200,
        "grpcStatus": "OK",
        "fault": null,
        "plan": null,
      },
    },
    {
      "kind": "close",
      "planned": { "status": null, "fault": "close", "plan": "close" },
      "without": {
        "status": 200,
        "grpcStatus": "OK",
        "fault": null,
        "plan": null,
      },
    },
    {
      "kind": "partial",
      "planned": {
        "status": 200,
        "grpcStatus": "OK",
        "fault": "partial",
        "plan": "partial",
      },
      "without": {
        "status": 200,
        "grpcStatus": "OK",
        "fault": null,
        "plan": null,
      },
    },
  ])
}
