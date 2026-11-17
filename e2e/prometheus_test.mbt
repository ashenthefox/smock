// The test of the reader of the Prometheus text exposition format, which is
// in prometheus_harness_test.mbt.

///|
test "the reader takes what Prometheus takes and rejects what it rejects" {
  let valid =
    #|# HELP a_total A counter, with \\ and \n.
    #|# TYPE a_total counter
    #|a_total{mock="x\"y",stub=""} 1
    #|a_total{mock="",stub="a\\b\nc",} 2 1700000000000
    #|# a comment
    #|
    #|# TYPE h histogram
    #|h_bucket{le="0.5"} 1
    #|h_bucket{le="+Inf"} 2
    #|h_sum 0.75
    #|h_count 2
    #|untyped_thing NaN
    #|
  let samples = parse_prometheus(valid)
  let out = [samples.map(sample => sample.line()).join("\n")]
  let invalid = [
    ("no final line feed", "a 1"),
    ("a bad metric name", "1a 1\n"),
    ("a bad label name", "a{1b=\"x\"} 1\n"),
    ("an unquoted label value", "a{b=x} 1\n"),
    ("a bad escape", "a{b=\"\\t\"} 1\n"),
    ("a label twice", "a{b=\"1\",b=\"2\"} 1\n"),
    ("a bad value", "a 1_000\n"),
    ("no value", "a{b=\"1\"}\n"),
    ("a series twice", "a 1\na 2\n"),
    ("TYPE twice", "# TYPE a counter\n# TYPE a counter\na 1\n"),
    ("TYPE after samples", "a 1\n# TYPE a counter\n"),
    ("lines apart", "# TYPE a counter\na{b=\"1\"} 1\nc 1\na{b=\"2\"} 1\n"),
    (
      "buckets going down", "# TYPE h histogram\nh_bucket{le=\"1\"} 2\nh_bucket{le=\"+Inf\"} 1\nh_sum 1\nh_count 1\n",
    ),
    (
      "no +Inf bucket", "# TYPE h histogram\nh_bucket{le=\"1\"} 1\nh_sum 1\nh_count 1\n",
    ),
    (
      "a count that is not the +Inf bucket", "# TYPE h histogram\nh_bucket{le=\"+Inf\"} 2\nh_sum 1\nh_count 1\n",
    ),
  ]
  for case in invalid {
    let (name, text) = case
    let verdict = try parse_prometheus(text) catch {
      _ => "rejected"
    } noraise {
      _ => "accepted"
    }
    out.push("\{name}: \{verdict}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|a_total{mock="x\"y",stub=""} 1
      #|a_total{mock="",stub="a\\b\nc"} 2
      #|h_bucket{le="0.5"} 1
      #|h_bucket{le="+Inf"} 2
      #|h_sum 0.75
      #|h_count 2
      #|untyped_thing NaN
      #|no final line feed: rejected
      #|a bad metric name: rejected
      #|a bad label name: rejected
      #|an unquoted label value: rejected
      #|a bad escape: rejected
      #|a label twice: rejected
      #|a bad value: rejected
      #|no value: rejected
      #|a series twice: rejected
      #|TYPE twice: rejected
      #|TYPE after samples: rejected
      #|lines apart: rejected
      #|buckets going down: rejected
      #|no +Inf bucket: rejected
      #|a count that is not the +Inf bucket: rejected
    ),
  )
}
