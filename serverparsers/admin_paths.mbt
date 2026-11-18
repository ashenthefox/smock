// The Admin API's path parameters: whether the path of a request fits the
// path of an operation, where `{name}` stands for one path segment, and the
// segment each name stands for. `server` holds the operations, with their
// paths as the Admin API's OpenAPI document, openapi/admin.json, gives them,
// and decodes each parameter once it is chosen.

///|
/// The path parameters of `path` when it fits the route path `template`,
/// where `{name}` stands for any one non-empty path segment: each name with
/// its segment, as sent. `None` when it does not fit.
pub fn path_params(template : String, path : String) -> Map[String, String]? {
  let expected = template.split("/").collect()
  let actual = path.split("/").collect()
  if expected.length() != actual.length() {
    return None
  }
  let params = Map([])
  for i, t in expected {
    let a = actual[i]
    if t.has_prefix("{") && t.has_suffix("}") && a != "" {
      params[t[1:t.length() - 1].to_owned()] = a.to_owned()
    } else if t != a {
      return None
    }
  }
  Some(params)
}
