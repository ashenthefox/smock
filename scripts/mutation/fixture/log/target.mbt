// Outside STR's scope: smock's log package keeps its reader of request
// targets in log/target.mbt, which STR does not mutate. The literal below
// is a skipped site, in each set.

///|
/// What a request target in origin form starts with.
pub let origin_start : String = "/"
