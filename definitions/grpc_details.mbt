// The error details of a gRPC Stub's reply, `response.grpc.details`: each
// an Any in ProtoJSON, `@type` beside the fields of its message, whose type
// is looked up in the Mock's set. An error's reply sends them in
// google.rpc.Status, which smock builds from the reply's status, its
// message and the details, so the codes never disagree and the set need
// not hold status.proto. Details as written are encoded when the files
// load; with `template` on, each is a structured template, rendered for
// each call, then encoded by the server.

///|
/// Reads `details`, the error details of a gRPC Stub's reply, the elements
/// of `details` at `pointer`, with the Mock's set `set`. The reply ends with
/// `status`, an error, and `message`, its status message as written.
/// `stub_pointer` is the JSON Pointer of the Stub.
///
/// Details as written are encoded at once into google.rpc.Status, in base64
/// without padding, as `grpc-status-details-bin` sends it; the first that
/// is not an Any of a type of the set, as `DescriptorSet::encode_status`
/// reads one, is reported at the JSON Pointer of the value at fault. With
/// `template` on, each is a structured template that may read the Data
/// buckets `buckets`: each must be an object with `@type`, and a `@type`
/// written without an expression must name a type of the set. A detail's
/// type, and every type it reaches, goes through the type checks of a
/// method's types (`File::check_reaching`).
fn File::read_details(
  self : File,
  stub_pointer : String,
  pointer : String,
  details : Array[Json],
  set : @protobuf.DescriptorSet,
  status : @grpc.Status,
  message : String,
  template~ : Bool,
  buckets~ : @template.Buckets,
) -> GrpcDetails {
  if template {
    let parsed = []
    for i, detail in details {
      let at = child_pointer(pointer, i.to_string())
      if !self.check_templated_detail(at, set, detail) {
        continue
      }
      match
        @template.Structured::parse(
          detail,
          pointer=template_pointer(stub_pointer, at),
          env=self.env,
          buckets~,
          role="a detail",
        ) {
        Ok(template) => parsed.push(template)
        Err(problems) =>
          for problem in problems {
            self.report_template_problem(stub_pointer, problem)
          }
      }
    }
    return Templated(ReadOnlyArray::from_array(parsed))
  }
  let written = ReadOnlyArray::from_array(details)
  let mut served = true
  for i, detail in details {
    if detail is Object(members) &&
      members.get("@type") is Some(String(url)) &&
      @protobuf.type_name_of_url(url) is Some(name) &&
      set.find_message(name) is Some(type_) {
      let at = child_pointer(child_pointer(pointer, i.to_string()), "@type")
      if !self.check_reaching(at, "detail", set, type_) {
        served = false
      }
    }
  }
  guard served else { return Written(written, None) }
  let encoded = set.encode_status(status.code(), message, details[:]) catch {
    EncodeError(pointer=at, message~) => {
      self.error(pointer + at, message)
      return Written(written, None)
    }
  }
  let value = @utf8.encode(@base64.encode(encoded, padding=false))
  Written(written, Some({ set, value, }))
}

///|
/// Checks `detail`, a templated error detail at `pointer`, as far as it can
/// be checked before it is rendered, and returns whether it passes: it
/// must be an object with `@type`, and a `@type` written without an
/// expression, without `$`, must be a type URL that names a type of `set`,
/// served as a method's types are (`File::check_reaching`). A `@type` with
/// an expression is checked once rendered.
fn File::check_templated_detail(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  detail : Json,
) -> Bool {
  guard detail is Object(members) else {
    self.error(
      pointer, "must be an object: a detail is an Any, the fields of its message beside \"@type\"",
    )
    return false
  }
  guard members.get("@type") is Some(type_url) else {
    self.error(
      pointer, "must give \"@type\", the type URL of the detail's message, such as \"type.googleapis.com/google.rpc.ErrorInfo\"",
    )
    return false
  }
  let at = child_pointer(pointer, "@type")
  match type_url {
    String(url) if url.contains("$") => true
    String(url) if @protobuf.type_name_of_url(url) is Some(name) =>
      match set.find_message(name) {
        Some(type_) => self.check_reaching(at, "detail", set, type_)
        None => {
          self.error(
            at,
            "names the type \{name}, which the Descriptor set does not define",
          )
          false
        }
      }
    _ => {
      self.error(
        at, "must be a type URL: / and the full name of a type of the set at its end, such as \"type.googleapis.com/helloworld.HelloRequest\"",
      )
      false
    }
  }
}
