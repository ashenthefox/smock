// A Mock's `grpc` field: the Descriptor set it names in the body-file
// subdirectory, read with the Definition files.

///|
/// A Descriptor set of one file, `a.proto`, with nothing in it.
let one_file_set : Bytes = b"\x0a\x09\x0a\x07a.proto"

///|
/// Loads `a.json`, which declares `mocks`, a JSON array, with the body
/// files `body_files`.
fn load_mocks(
  mocks : String,
  body_files~ : Array[(String, Bytes)] = [],
) -> Result[@definitions.Snapshot, Array[@definitions.Diagnostic]] {
  @definitions.load({
    files: [("a.json", @utf8.encode("{ \"mocks\": \{mocks} }"))],
    body_files,
  })
}

///|
/// What `load_mocks` gives: each Mock's name and the files of its set, one
/// line each, or every problem, one per line.
fn mock_sets(
  mocks : String,
  body_files~ : Array[(String, Bytes)] = [],
) -> String {
  match load_mocks(mocks, body_files~) {
    Ok(snapshot) =>
      snapshot.mocks
      .iter()
      .map(mock => {
        let files = match mock.descriptor_set {
          Some(set) => set.files.map(file => file.name).join(", ")
          None => "no set"
        }
        "\{mock.name}: \{files}"
      })
      .collect()
      .join("\n")
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
test "a Mock's grpc.descriptorSet names a Descriptor set in the body-file subdirectory, which the Mock holds decoded" {
  inspect(
    mock_sets(
      (
        #|[{ "name": "greeter", "grpc": { "descriptorSet": "protos/greeter.binpb" } },
        #| { "name": "users" }]
      ),
      body_files=[("protos/greeter.binpb", one_file_set)],
    ),
    content=(
      #|greeter: a.proto
      #|users: no set
    ),
  )
}

///|
test "grpc is a closed object whose descriptorSet is a string, and health and reflection booleans" {
  inspect(
    mock_sets(
      (
        #|[{ "name": "a", "grpc": "greeter.binpb" },
        #| { "name": "b", "grpc": { "health": "yes" } },
        #| { "name": "c", "grpc": { "descriptorSet": 1 } },
        #| { "name": "d", "grpc": { "descriptorSet": "a.binpb", "streaming": true } },
        #| { "name": "e", "grpc": { "descriptorSet": "a.binpb", "reflection": "true" } }]
      ),
      body_files=[("a.binpb", one_file_set)],
    ),
    content=(
      #|a.json: /mocks/0/grpc: must be an object
      #|a.json: /mocks/1/grpc/health: must be true or false
      #|a.json: /mocks/2/grpc/descriptorSet: must be a string
      #|a.json: /mocks/3/grpc/streaming: is not a known field
      #|a.json: /mocks/4/grpc/reflection: must be true or false
    ),
  )
}

///|
test "grpc.reflection, false by default, makes the Mock keep each file of its set as the set encodes it, without its source info, and a Mock without it keeps none" {
  // a.proto, with source info, field 9, after its name.
  let with_source_info = b"\x0a\x0d\x0a\x07a.proto\x4a\x02\x0a\x00"
  let snapshot = load_mocks(
    (
      #|[{ "name": "a", "grpc": { "reflection": true, "descriptorSet": "a.binpb" } },
      #| { "name": "b", "grpc": { "descriptorSet": "a.binpb", "reflection": false } },
      #| { "name": "c", "grpc": { "descriptorSet": "a.binpb" } },
      #| { "name": "d", "grpc": { "reflection": true } },
      #| { "name": "e" }]
    ),
    body_files=[("a.binpb", with_source_info)],
  ).unwrap()
  inspect(
    snapshot.mocks
    .iter()
    .map(mock => {
      let kept = match mock.reflection {
        Some(files) =>
          "reflection, files [\{files.iter().map(file => @hex.encode(file)).collect().join(", ")}]"
        None => "no reflection"
      }
      "\{mock.name}: \{kept}"
    })
    .collect()
    .join("\n"),
    content=(
      #|a: reflection, files [0a07612e70726f746f]
      #|b: no reflection
      #|c: no reflection
      #|d: reflection, files []
      #|e: no reflection
    ),
  )
}

///|
test "grpc.health turns the Mock's health service on, false by default, and descriptorSet may be left out" {
  let snapshot = load_mocks(
    (
      #|[{ "name": "a", "grpc": { "descriptorSet": "a.binpb", "health": true } },
      #| { "name": "b", "grpc": { "health": true } },
      #| { "name": "c", "grpc": { "descriptorSet": "a.binpb", "health": false } },
      #| { "name": "d", "grpc": {} },
      #| { "name": "e" }]
    ),
    body_files=[("a.binpb", one_file_set)],
  ).unwrap()
  inspect(
    snapshot.mocks
    .iter()
    .map(mock => {
      let set = if mock.descriptor_set is Some(_) { "a set" } else { "no set" }
      "\{mock.name}: \{set}, health \{mock.health}"
    })
    .collect()
    .join("\n"),
    content=(
      #|a: a set, health true
      #|b: no set, health true
      #|c: a set, health false
      #|d: no set, health false
      #|e: no set, health false
    ),
  )
}

///|
test "a descriptorSet that names no body file, leaves the body-file subdirectory or names a dot file is one problem at descriptorSet" {
  inspect(
    mock_sets(
      (
        #|[{ "name": "a", "grpc": { "descriptorSet": "missing.binpb" } },
        #| { "name": "b", "grpc": { "descriptorSet": "../greeter.binpb" } },
        #| { "name": "c", "grpc": { "descriptorSet": "protos/.greeter.binpb" } },
        #| { "name": "d", "grpc": { "descriptorSet": "/greeter.binpb" } }]
      ),
      body_files=[("greeter.binpb", one_file_set)],
    ),
    content=(
      #|a.json: /mocks/0/grpc/descriptorSet: no body file "missing.binpb" in the body-file subdirectory
      #|a.json: /mocks/1/grpc/descriptorSet: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /mocks/2/grpc/descriptorSet: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /mocks/3/grpc/descriptorSet: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
    ),
  )
}

///|
test "a descriptorSet whose file does not decode as a FileDescriptorSet is one problem at descriptorSet, naming where it breaks" {
  inspect(
    mock_sets(
      (
        #|[{ "name": "a", "grpc": { "descriptorSet": "users.json" } },
        #| { "name": "b", "grpc": { "descriptorSet": "cut.binpb" } }]
      ),
      body_files=[
        ("users.json", b"{\"id\": 1}"),
        ("cut.binpb", one_file_set[:5].to_owned()),
      ],
    ),
    content=(
      #|a.json: /mocks/0/grpc/descriptorSet: "users.json": not a Descriptor set, a FileDescriptorSet in protobuf's binary encoding: octet 2: a length of 105 runs past the end of the input, which has 6 octets left
      #|a.json: /mocks/1/grpc/descriptorSet: "cut.binpb": not a Descriptor set, a FileDescriptorSet in protobuf's binary encoding: octet 1: a length of 9 runs past the end of the input, which has 3 octets left
    ),
  )
}

///|
test "a descriptorSet that decodes but is not self-contained gives each of its problems at descriptorSet" {
  // The file a.proto, which imports b.proto, twice.
  let a_proto = b"\x0a\x12\x0a\x07a.proto\x1a\x07b.proto"
  inspect(
    mock_sets(
      (
        #|[{ "name": "a", "grpc": { "descriptorSet": "a.binpb" } }]
      ),
      body_files=[("a.binpb", a_proto + a_proto)],
    ),
    content=(
      #|a.json: /mocks/0/grpc/descriptorSet: "a.binpb": the file a.proto is in the set more than once
      #|a.json: /mocks/0/grpc/descriptorSet: "a.binpb": a.proto imports b.proto, which is not in the set; build the set with protoc --include_imports, or with buf build
    ),
  )
}
