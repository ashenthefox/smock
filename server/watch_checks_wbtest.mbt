// What the checks of a watch do with what they read: the definitions
// directory's reloader and the certificates. An `Unsure` check reads at the
// poll, with no quiet period, so it can find a file half written: it acts
// on nothing, and when it reads something new, the watch checks again,
// `Changed`, once the change has settled, and that check acts (#384). The
// watches' own schedule is for the tests of the watch package.

///|
/// The message of each log entry in `lines`, with its result or error, if
/// any, one entry a line.
fn entries(lines : Array[String]) -> String {
  lines
  .map(line => {
    let parsed = Some(@json.parse(line)) catch { _ => None }
    guard parsed is Some(Object(entry)) && entry.get("msg") is Some(String(msg)) else {
      return "not a log entry: \{line}"
    }
    match (entry.get("result"), entry.get("error")) {
      (Some(String(result)), _) => "\{msg}: \{result}"
      (_, Some(String(error))) => "\{msg}: \{error}"
      _ => msg
    }
  })
  .join("\n")
}

///|
/// A watch whose stamps note nothing that changes, as on a file system
/// whose file times are too coarse to show a change made soon after
/// another: only a read finds such a change, and the watch checks again
/// only when its caller tells it that a read found one.
async fn blind_watch() -> @watch.Watch {
  @watch.Watch(stamp=stamp => stamp.note("the same"))
}

///|
/// Runs `run`, a caller's loop over the checks of a watch, until something
/// is logged into `lines`, or for 2 s, then stops it.
async fn run_until_logged(
  lines : Array[String],
  run : async () -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, run)
    let _ = @async.with_timeout_opt(2000, () => {
      while lines.is_empty() {
        @async.sleep(10)
      }
    })
  })
}

///|
async test "an Unsure check of the definitions reloads nothing, though it reads a set other than the one read last, as when a file is rewritten in place right after the poll's stamp, and the watch checks again once the change has settled, which reloads the set" {
  // docs/definition-files.md, Reloading: smock reads changed files "once
  // they have stayed the same for 250 ms", so "a change made of several
  // writes ... gives one reload of them all".
  let dir = @fs.tmpdir(prefix="smock-reload-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.mkdir("\{dir}/files")
  let mocks = "{ \"mocks\": [{ \"name\": \"m\" }] }"
  let users = "{ \"stubs\": [{ \"id\": \"get-user\", \"mock\": \"m\", \"request\": { \"method\": \"GET\", \"path\": \"/users/1\" }, \"response\": { \"status\": 200 } }] }"
  @fs.write_file("\{dir}/mocks.json", mocks)
  @fs.write_file("\{dir}/users.json", users)
  let snapshot = match
    @defdir.load(Some(dir), body_file_dir="files", env=@template.no_env) {
    Ok(snapshot) => snapshot
    Err(problems) =>
      fail(
        "the first set does not load: \{problems.map(p => p.message).join("; ")}",
      )
  }
  let engine = @engine.Engine(snapshot)
  let lines = []
  let reloader : Reloader = {
    dir,
    body_file_dir: "files",
    engine,
    logger: @log.Logger(write_line=line => lines.push(line), now=() => 0),
    reloads: register_reload_metric(@metrics.Registry()),
    last_read: (snapshot.digest, []),
    after_swap: () => (),
  }
  let watch = blind_watch()
  let served = () => {
    if engine.status().digest == snapshot.digest {
      "the first set"
    } else {
      "another set"
    }
  }
  let out = []
  let check = async fn(label : String, check : @watch.Check) {
    let read_whole = reloader.check(check, watch)
    out.push(
      (
        $|\{label}: read whole \{read_whole}, serves \{served()}
        $|\{entries(lines)}
      ),
    )
    lines.clear()
  }
  check("Unsure, nothing changed", Unsure)
  // mocks.json truncated, and not yet written again.
  @fs.write_file("\{dir}/mocks.json", "")
  check("Unsure, mocks.json empty", Unsure)
  // The Mock renamed, and its Stub not yet moved to the new name.
  let renamed = mocks.replace(old="\"m\"", new="\"people\"")
  @fs.write_file("\{dir}/mocks.json", renamed)
  check("Unsure, mocks.json written, users.json not yet", Unsure)
  @fs.write_file(
    "\{dir}/users.json",
    users.replace(old="\"m\"", new="\"people\""),
  )
  // The stamps note no change, so only the reads above can have the watch
  // check again.
  run_until_logged(lines, () => reloader.run(watch))
  out.push(
    (
      $|both written, the watch's next check: serves \{served()}
      $|\{entries(lines)}
    ),
  )
  inspect(
    out.join("\n"),
    content=(
      #|Unsure, nothing changed: read whole true, serves the first set
      #|
      #|Unsure, mocks.json empty: read whole true, serves the first set
      #|
      #|Unsure, mocks.json written, users.json not yet: read whole true, serves the first set
      #|
      #|both written, the watch's next check: serves another set
      #|definitions reloaded: swapped
    ),
  )
}

///|
async test "an Unsure check of the certificates loads nothing, though a pair's files differ from those read last, as when a certificate is rewritten in place right after the poll's stamp, before its key, and the watch checks again once the change has settled, which loads the pair" {
  // docs/running.md, Rotating certificates: "a certificate and its key
  // written less than 250 ms apart are loaded together".
  let dir = @fs.tmpdir(prefix="smock-certificates-")
  defer @fs.rmdir(dir, recursive=true)
  let files : @settings.TlsFiles = {
    cert_file: "\{dir}/tls.crt",
    key_file: "\{dir}/tls.key",
  }
  @fs.write_file(files.cert_file, @testcerts.rsa_chain + "\n")
  @fs.write_file(files.key_file, @testcerts.rsa_key + "\n")
  guard @defdir.load(None, body_file_dir="files", env=@template.no_env)
    is Ok(snapshot) else {
    fail("the empty set does not load")
  }
  let lines = []
  guard Certificates::load(
      Some(files),
      Map([]),
      alpn=["http/1.1"],
      engine=@engine.Engine(snapshot),
      logger=@log.Logger(write_line=line => lines.push(line), now=() => 0),
      metrics=@metrics.Registry(),
    )
    is Some(certificates) else {
    fail("the first pair does not load: \{lines.join("\n")}")
  }
  guard certificates.default is Files(pair) else { fail("no default pair") }
  let first = pair.config
  let watch = blind_watch()
  let presented = () => {
    if physical_equal(pair.config, first) {
      "the first pair"
    } else {
      "another pair"
    }
  }
  let out = []
  let check = async fn(label : String, check : @watch.Check) {
    let read_all = certificates.check(check, watch)
    out.push(
      (
        $|\{label}: read all \{read_all}, presents \{presented()}
        $|\{entries(lines)}
      ),
    )
    lines.clear()
  }
  check("Unsure, nothing changed", Unsure)
  // The certificate truncated, and not yet written again.
  @fs.write_file(files.cert_file, "")
  check("Unsure, the certificate empty", Unsure)
  @fs.write_file(files.cert_file, @testcerts.ecdsa_chain + "\n")
  check("Unsure, the certificate written, its key not yet", Unsure)
  @fs.write_file(files.key_file, @testcerts.ecdsa_key + "\n")
  // The stamps note no change, so only the reads above can have the watch
  // check again.
  run_until_logged(lines, () => certificates.run(watch))
  out.push(
    (
      $|both written, the watch's next check: presents \{presented()}
      $|\{entries(lines)}
    ),
  )
  inspect(
    out.join("\n"),
    content=(
      #|Unsure, nothing changed: read all true, presents the first pair
      #|
      #|Unsure, the certificate empty: read all true, presents the first pair
      #|
      #|Unsure, the certificate written, its key not yet: read all true, presents the first pair
      #|
      #|both written, the watch's next check: presents another pair
      #|TLS certificate reloaded
    ),
  )
}
