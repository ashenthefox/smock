// The Journal's byte bound at startup: what --journal-max-bytes or
// SMOCK_JOURNAL_MAX_BYTES sets, or else a quarter of the memory limit of
// smock's cgroup. smock runs in a systemd user scope with MemoryMax, as
// bench/bench.py runs it, so that its cgroup has a known memory limit.

///|
async test "journal byte bound: a quarter of the memory limit of smock's cgroup, unless the flag or the variable sets it" {
  if scope_unavailable() is Some(reason) {
    println(
      "skipped \"journal byte bound\" (e2e/journal_bound_test.mbt): it runs smock in a systemd user scope with a memory limit, but \{reason}",
    )
    return
  }
  let cases : Array[(Array[String], Map[String, String])] = [
    ([], {}),
    (["--journal-max-bytes", "1000000"], {}),
    ([], { "SMOCK_JOURNAL_MAX_BYTES": "2000000" }),
  ]
  let out = []
  for case in cases {
    let (args, env) = case
    let stopped = with_smock(
      ["--port", "0", ..args],
      env=user_manager_env(env),
      under=in_scope,
      _ => (),
    )
    out.push(startup_entry(stopped.logs, "journal byte bound"))
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"level":"info","msg":"journal byte bound","maxBytes":13631488,"source":"memoryLimit","memoryLimit":54525952}
      #|{"level":"info","msg":"journal byte bound","maxBytes":1000000,"source":"flag"}
      #|{"level":"info","msg":"journal byte bound","maxBytes":2000000,"source":"variable"}
    ),
  )
}

///|
async test "journal byte bound: the Journal holds no more than the bound smock logs, and evicts beyond it" {
  with_definitions([("users.json", journal_defs)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--journal-max-bytes", "1000"],
      smock => {
        // Each entry counts at least 256 bytes, so four overflow the bound.
        for i in 1..<=4 {
          let _ = smock.request("GET", "/users/\{i}", headers=[
            ("Host", "localhost"),
          ])
        }
        let text = smock.admin("GET", "/metrics").body
        let bytes = metric_value(text, "smock_journal_bytes")
        let evictions = metric_value(text, "smock_journal_evictions_total")
        inspect(
          "within the bound: \{bytes > 0.0 && bytes <= 1000.0}, evicted: \{evictions > 0.0}",
          content="within the bound: true, evicted: true",
        )
      },
    )
    inspect(
      startup_entry(stopped.logs, "journal byte bound"),
      content=(
        #|{"level":"info","msg":"journal byte bound","maxBytes":1000,"source":"flag"}
      ),
    )
  })
}
