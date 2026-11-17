// The Admin API contract: Seam 2 tests check every Admin API response they
// get against the OpenAPI document, openapi/admin.json. The checker below
// knows the JSON Schema keywords the document uses. A keyword it does not
// know is reported as a problem, never skipped, so that a check cannot pass
// by ignoring part of a schema.

///|
/// The OpenAPI document, relative to the module root.
let document : String = "openapi/admin.json"

///|
/// The OpenAPI document and the JSON Schemas it refers to, by their paths
/// relative to the module root.
struct Contract {
  files : Map[String, Json]
}

///|
/// The contract, read once per test process.
let contract : @async.Lazy[Contract] = @async.Lazy(() => {
  let files = Map([])
  let pending = [document]
  while pending.pop() is Some(path) {
    if files.contains(path) {
      continue
    }
    let json = @fs.read_file(path).json()
    files[path] = json
    for reference in refs(json) {
      let file = ref_file(reference)
      if file != "" {
        pending.push(join_path(path, file))
      }
    }
  }
  { files, }
})

///|
/// Every `$ref` in `json`.
fn refs(json : Json) -> Array[String] {
  let out = []
  fn walk(json : Json) {
    match json {
      Object(members) =>
        for key, value in members {
          match (key, value) {
            ("$ref", String(reference)) => out.push(reference)
            _ => walk(value)
          }
        }
      Array(items) =>
        for item in items {
          walk(item)
        }
      _ => ()
    }
  }
  walk(json)
  out
}

///|
/// The file part of a reference: what comes before `#`.
fn ref_file(reference : String) -> String {
  match reference.find("#") {
    Some(i) => reference[:i].to_owned()
    None => reference
  }
}

///|
/// The path of `relative`, a path relative to the file at `base`.
fn join_path(base : String, relative : String) -> String {
  let parts : Array[String] = base.split("/").map(p => p.to_owned()).collect()
  let _ = parts.pop()
  for part in relative.split("/") {
    match part {
      "." | "" => ()
      ".." => {
        let _ = parts.pop()
      }
      _ => parts.push(part.to_owned())
    }
  }
  parts.join("/")
}

///|
/// A schema or another part of a file of the contract.
struct Located {
  /// The file it is in.
  file : String
  json : Json
}

///|
/// What `reference`, found in `file`, refers to.
fn Contract::resolve(
  self : Contract,
  file : String,
  reference : String,
) -> Located raise {
  let target = match ref_file(reference) {
    "" => file
    other => join_path(file, other)
  }
  guard self.files.get(target) is Some(root) else {
    fail("\{reference}: no file \{target}")
  }
  let pointer = match reference.find("#") {
    Some(i) => reference[i + 1:].to_owned()
    None => ""
  }
  let mut json = root
  if pointer != "" {
    for token in pointer[1:].split("/") {
      let key = token
        .replace_all(old="~1", new="/")
        .replace_all(old="~0", new="~")
      json = match json {
        Object(members) =>
          match members.get(key.to_owned()) {
            Some(value) => value
            None => fail("\{reference}: no member \{key.escape()} in \{target}")
          }
        _ =>
          fail("\{reference}: \{key.escape()} is not in an object in \{target}")
      }
    }
  }
  { file: target, json, }
}

///|
/// Follows `located` while it is a reference object, as OpenAPI responses,
/// parameters and headers can be.
fn Contract::follow(self : Contract, located : Located) -> Located raise {
  let mut at = located
  while at.json is Object(members) &&
        members.get("$ref") is Some(String(reference)) {
    at = self.resolve(at.file, reference)
  }
  at
}

///|
/// The problems with `response` as the answer to `meth path`, by the
/// document: none when it conforms. A path the document does not list, or a
/// method it does not list for the path, must be answered as the document's
/// `Error` response says.
fn Contract::check(
  self : Contract,
  meth : String,
  path : String,
  response : AdminResponse,
) -> Array[String] raise {
  let path = match path.find("?") {
    Some(i) => path[:i].to_owned()
    None => path
  }
  guard self.files[document] is Object(root) &&
    root.get("paths") is Some(Object(paths)) else {
    fail("\{document} has no paths")
  }
  let mut item = None
  for template, value in paths {
    if path_matches(template, path) {
      item = Some(value)
    }
  }
  let operation = match item {
    Some(Object(item)) =>
      match item.get(meth.to_lower()) {
        Some(Object(operation)) => Some(operation)
        _ => None
      }
    _ => None
  }
  let response_object = match operation {
    None => self.resolve(document, "#/components/responses/Error")
    Some(operation) => {
      guard operation.get("responses") is Some(Object(responses)) else {
        fail("\{meth} \{path} has no responses in \{document}")
      }
      let status = response.status.to_string()
      let keys = [status, "\{status[:1]}XX", "default"]
      match keys.iter().filter_map(key => responses.get(key)).head() {
        Some(object) => { file: document, json: object, }
        None => return ["\{meth} \{path} documents no \{status} response"]
      }
    }
  }
  self.check_response(response_object, response)
}

///|
/// Whether `path` fits `template`, such as `/v1/mocks/users/stubs` and
/// `/v1/mocks/{mock}/stubs`.
fn path_matches(template : String, path : String) -> Bool {
  let expected = template.split("/").collect()
  let actual = path.split("/").collect()
  expected.length() == actual.length() &&
  expected
  .iter()
  .zip(actual.iter())
  .all(pair => {
    let (t, a) = pair
    (t.has_prefix("{") && t.has_suffix("}") && a != "") || t == a
  })
}

///|
/// The problems with `response` by the OpenAPI response object `object`.
fn Contract::check_response(
  self : Contract,
  object : Located,
  response : AdminResponse,
) -> Array[String] raise {
  let object = self.follow(object)
  guard object.json is Object(members) else {
    fail("a response object is not an object")
  }
  let problems = []
  if members.get("headers") is Some(Object(headers)) {
    for name, header in headers {
      let header = self.follow({ file: object.file, json: header, })
      guard header.json is Object(header_members) else { continue }
      match response.header(name) {
        Some(value) =>
          match header_members.get("schema") {
            Some(schema) =>
              self.validate(
                { file: header.file, json: schema, },
                Json::string(value),
                "header \{name}",
                problems,
              )
            None => ()
          }
        None =>
          if header_members.get("required") is Some(True) {
            problems.push("header \{name} is missing")
          }
      }
    }
  }
  match members.get("content") {
    Some(Object(content)) => {
      let media_type = match response.header("Content-Type") {
        Some(value) =>
          match value.find(";") {
            Some(i) => value[:i].trim().to_lower()
            None => value.trim().to_lower()
          }
        None => {
          problems.push("header Content-Type is missing")
          return problems
        }
      }
      guard content.get(media_type.to_owned()) is Some(Object(media)) else {
        problems.push("content type \{media_type} is not documented")
        return problems
      }
      let body = if media_type == "application/json" {
        @json.parse(response.body) catch {
          err => {
            problems.push("the body is not JSON: \{err}")
            return problems
          }
        }
      } else {
        Json::string(response.body)
      }
      match media.get("schema") {
        Some(schema) =>
          self.validate(
            { file: object.file, json: schema, },
            body,
            "",
            problems,
          )
        None => ()
      }
    }
    _ =>
      if response.body != "" {
        problems.push("the response documents no body, but has one")
      }
  }
  problems
}

///|
/// Keywords that only annotate a schema.
let annotations : Set[String] = Set::from_array([
  "description", "title", "default", "examples", "example", "format", "deprecated",
  "readOnly", "writeOnly", "$comment", "$id", "$schema", "contentMediaType", "contentEncoding",
])

///|
/// Validates `value` against `schema`, adding a problem for each way it
/// fails, each prefixed with `at`, a JSON Pointer to the value.
fn Contract::validate(
  self : Contract,
  schema : Located,
  value : Json,
  at : String,
  problems : Array[String],
) -> Unit raise {
  let file = schema.file
  let members = match schema.json {
    True => return
    False => {
      problems.push("\{at}: no value is allowed here")
      return
    }
    Object(members) => members
    _ => fail("a schema in \{file} is neither an object nor a boolean")
  }
  let sub = (json : Json) => Located::{ file, json, }
  for keyword, argument in members {
    match (keyword, argument) {
      (k, _) if annotations.contains(k) => ()
      ("$ref", String(reference)) =>
        self.validate(self.resolve(file, reference), value, at, problems)
      ("type", String(t)) =>
        if !has_type(value, t) {
          problems.push("\{at}: \{describe(value)} is not of type \{t}")
        }
      ("type", Array(types)) =>
        if !types.iter().any(t => t is String(t) && has_type(value, t)) {
          problems.push(
            "\{at}: \{describe(value)} is not of type \{argument.stringify()}",
          )
        }
      ("enum", Array(allowed)) =>
        if !allowed.contains(value) {
          problems.push(
            "\{at}: \{describe(value)} is not one of \{argument.stringify()}",
          )
        }
      ("const", _) =>
        if value != argument {
          problems.push(
            "\{at}: \{describe(value)} is not \{argument.stringify()}",
          )
        }
      ("properties", Object(properties)) =>
        if value is Object(object) {
          for name, property in properties {
            if object.get(name) is Some(v) {
              self.validate(sub(property), v, "\{at}/\{name}", problems)
            }
          }
        }
      ("required", Array(required)) =>
        if value is Object(object) {
          for name in required {
            if name is String(name) && !object.contains(name) {
              problems.push("\{at}: \{name} is missing")
            }
          }
        }
      ("patternProperties", Object(patterns)) =>
        if value is Object(object) {
          for name, v in object {
            for pattern, property in patterns {
              if matches(pattern, name, file) {
                self.validate(sub(property), v, "\{at}/\{name}", problems)
              }
            }
          }
        }
      ("additionalProperties", _) =>
        if value is Object(object) {
          let known = match members.get("properties") {
            Some(Object(properties)) => properties
            _ => Map([])
          }
          let patterns = match members.get("patternProperties") {
            Some(Object(patterns)) => patterns
            _ => Map([])
          }
          for name, v in object {
            if !known.contains(name) && !matches_any(patterns, name, file) {
              self.validate(sub(argument), v, "\{at}/\{name}", problems)
            }
          }
        }
      ("unevaluatedProperties", _) =>
        if value is Object(object) {
          let seen : Set[String] = Set([])
          for other, other_argument in members {
            if other != keyword {
              self.evaluated_by(other, other_argument, file, value, seen)
            }
          }
          for name, v in object {
            if !seen.contains(name) {
              self.validate(sub(argument), v, "\{at}/\{name}", problems)
            }
          }
        }
      ("propertyNames", _) =>
        if value is Object(object) {
          for name, _ in object {
            self.validate(
              sub(argument),
              Json::string(name),
              "\{at} (name \{name})",
              problems,
            )
          }
        }
      ("dependentSchemas", Object(dependents)) =>
        if value is Object(object) {
          for name, dependent in dependents {
            if object.contains(name) {
              self.validate(sub(dependent), value, at, problems)
            }
          }
        }
      ("items", _) =>
        if value is Array(items) {
          for i, item in items {
            self.validate(sub(argument), item, "\{at}/\{i}", problems)
          }
        }
      ("minItems", Number(n, ..)) =>
        if value is Array(items) && items.length().to_double() < n {
          problems.push("\{at}: fewer than \{n} items")
        }
      ("maxItems", Number(n, ..)) =>
        if value is Array(items) && items.length().to_double() > n {
          problems.push("\{at}: more than \{n} items")
        }
      ("allOf", Array(schemas)) =>
        for s in schemas {
          self.validate(sub(s), value, at, problems)
        }
      ("anyOf", Array(schemas)) => {
        let passing = schemas.filter(s => self.passes(sub(s), value))
        if passing.is_empty() {
          problems.push("\{at}: \{describe(value)} matches none of anyOf")
        }
      }
      ("oneOf", Array(schemas)) => {
        let passing = schemas.filter(s => self.passes(sub(s), value))
        if passing.length() != 1 {
          problems.push(
            "\{at}: \{describe(value)} matches \{passing.length()} of oneOf, not 1",
          )
        }
      }
      ("not", _) =>
        if self.passes(sub(argument), value) {
          problems.push(
            "\{at}: \{describe(value)} matches a schema it must not",
          )
        }
      // `then` applies where `if` holds, and `else` where it does not.
      ("if", _) => {
        let branch = if self.passes(sub(argument), value) {
          "then"
        } else {
          "else"
        }
        if members.get(branch) is Some(schema) {
          self.validate(sub(schema), value, at, problems)
        }
      }
      // Applied by `if`; without one, they apply nowhere.
      ("then" | "else", _) => ()
      ("minimum", Number(n, ..)) =>
        if value is Number(v, ..) && v < n {
          problems.push("\{at}: \{v} is below \{n}")
        }
      ("maximum", Number(n, ..)) =>
        if value is Number(v, ..) && v > n {
          problems.push("\{at}: \{v} is above \{n}")
        }
      ("minLength", Number(n, ..)) =>
        if value is String(s) && s.char_length().to_double() < n {
          problems.push("\{at}: \{s.escape()} is shorter than \{n}")
        }
      ("maxLength", Number(n, ..)) =>
        if value is String(s) && s.char_length().to_double() > n {
          problems.push("\{at}: \{s.escape()} is longer than \{n}")
        }
      ("pattern", String(pattern)) =>
        if value is String(s) && !matches(pattern, s, file) {
          problems.push("\{at}: \{s.escape()} does not match \{pattern}")
        }
      _ =>
        problems.push(
          "\{at}: the contract checker does not know the keyword \{keyword} in \{file}",
        )
    }
  }
}

///|
/// Adds to `seen` the names of the properties of `value`, an object, that
/// the keyword `keyword` with `argument`, in a schema in `file`, evaluates:
/// those `properties` names, those a `patternProperties` pattern matches,
/// every one for `additionalProperties` and
/// `unevaluatedProperties`, and those that the subschemas applied in place
/// evaluate (`$ref`, `allOf`, the passing ones of `anyOf` and `oneOf`, and
/// `dependentSchemas`). The properties no keyword evaluates are the ones
/// `unevaluatedProperties` applies to.
fn Contract::evaluated_by(
  self : Contract,
  keyword : String,
  argument : Json,
  file : String,
  value : Json,
  seen : Set[String],
) -> Unit raise {
  guard value is Object(object) else { return }
  let in_place = (schema : Located) => {
    if schema.json is Object(members) {
      for k, a in members {
        self.evaluated_by(k, a, schema.file, value, seen)
      }
    }
  }
  let sub = (json : Json) => Located::{ file, json, }
  match (keyword, argument) {
    ("properties", Object(properties)) =>
      for name, _ in object {
        if properties.contains(name) {
          seen.add(name)
        }
      }
    ("patternProperties", Object(patterns)) =>
      for name, _ in object {
        if matches_any(patterns, name, file) {
          seen.add(name)
        }
      }
    ("additionalProperties" | "unevaluatedProperties", _) =>
      for name, _ in object {
        seen.add(name)
      }
    ("$ref", String(reference)) => in_place(self.resolve(file, reference))
    ("allOf", Array(schemas)) =>
      for s in schemas {
        in_place(sub(s))
      }
    ("anyOf" | "oneOf", Array(schemas)) =>
      for s in schemas {
        if self.passes(sub(s), value) {
          in_place(sub(s))
        }
      }
    ("dependentSchemas", Object(dependents)) =>
      for name, dependent in dependents {
        if object.contains(name) {
          in_place(sub(dependent))
        }
      }
    _ => ()
  }
}

///|
/// Whether `pattern`, a regular expression in a schema in `file`, matches
/// somewhere in `s`.
fn matches(pattern : String, s : String, file : String) -> Bool raise {
  let regex = @re2.compile(re2_syntax(pattern)) catch {
    err => fail("pattern \{pattern.escape()} in \{file}: \{err}")
  }
  regex.search(@utf8.encode(s)) is Some(_)
}

///|
/// Whether a pattern of `patterns`, the argument of `patternProperties` in
/// a schema in `file`, matches the name `name`.
fn matches_any(
  patterns : Map[String, Json],
  name : String,
  file : String,
) -> Bool raise {
  for pattern, _ in patterns {
    if matches(pattern, name, file) {
      return true
    }
  }
  false
}

///|
/// `pattern`, an ECMA-262 regular expression as JSON Schema writes it, in
/// the RE2 subset of `smock/re2`: its `\uXXXX`, `\r`, `\n` and `\t`
/// escapes, which the subset lacks, as the characters they stand for. The
/// patterns of the contract use no other syntax that the subset lacks.
fn re2_syntax(pattern : String) -> String {
  let out = StringBuilder()
  let mut i = 0
  while i < pattern.length() {
    if pattern[i] == '\\' && i + 1 < pattern.length() {
      match pattern[i + 1] {
        'u' if i + 6 <= pattern.length() => {
          let mut code = 0
          for c in pattern[i + 2:i + 6] {
            let digit = match c {
              '0'..<='9' => c.to_int() - '0'.to_int()
              'a'..<='f' => c.to_int() - 'a'.to_int() + 10
              _ => c.to_int() - 'A'.to_int() + 10
            }
            code = code * 16 + digit
          }
          out.write_char(code.unsafe_to_char())
          i += 6
        }
        'r' => {
          out.write_char('\r')
          i += 2
        }
        'n' => {
          out.write_char('\n')
          i += 2
        }
        't' => {
          out.write_char('\t')
          i += 2
        }
        _ => {
          out.write_string(pattern[i:i + 2].to_owned())
          i += 2
        }
      }
    } else {
      out.write_char(pattern[i].unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
/// Whether `value` is valid against `schema`.
fn Contract::passes(self : Contract, schema : Located, value : Json) -> Bool {
  let problems = []
  self.validate(schema, value, "", problems) catch {
    _ => return false
  }
  problems.is_empty()
}

///|
fn has_type(value : Json, t : String) -> Bool {
  match (t, value) {
    ("object", Object(_)) => true
    ("array", Array(_)) => true
    ("string", String(_)) => true
    ("number", Number(_, ..)) => true
    ("integer", Number(n, ..)) => n == n.floor()
    ("boolean", True | False) => true
    ("null", Null) => true
    _ => false
  }
}

///|
fn describe(value : Json) -> String {
  let text = value.stringify()
  if text.length() > 60 {
    text[:57].to_owned() + "..."
  } else {
    text
  }
}

///|
/// Fails the test unless `response`, the answer to `meth path`, conforms to
/// the document.
async fn conforms(
  meth : String,
  path : String,
  response : AdminResponse,
) -> Unit {
  let problems = contract.wait().check(meth, path, response)
  if !problems.is_empty() {
    fail(
      "\{meth} \{path} does not conform to \{document}:\n\{problems.join("\n")}\n\n\{response.status}\n\{response.body}",
    )
  }
}
