// What the checks of a watch do with what they read: the definitions
// directory's reloader and the certificates. An `Unsure` check reads at the
// poll, with no quiet period, so it can find a file half written: it acts
// on nothing, and when it reads something new, the watch checks again,
// `Changed`, once the change has settled, and that check acts (#384). So
// it is while a problem reading the files lasts, when each other check has
// the watch forget its stamp: such a check tells that it read everything,
// so that the watch keeps the stamp that the quiet period compares with.
// The watches' own schedule is for the tests of the watch package.

///|
/// The message of each log entry in `lines`, with the Mock whose pair it
/// names in brackets, when that is not the default certificate, and its
/// result or error, if any, one entry a line. Below an entry with errors,
/// such as a failed reload, each of them, indented, as `smock check` prints
/// a problem: the file, the pointer if any, and the message.
fn entries(lines : Array[String]) -> String {
  lines
  .map(line => {
    let parsed = Some(@json.parse(line)) catch { _ => None }
    guard parsed is Some(Object(entry)) && entry.get("msg") is Some(String(msg)) else {
      return "not a log entry: \{line}"
    }
    let msg = match entry.get("mock") {
      Some(String(mock)) if mock != "" => "\{msg} (\{mock})"
      _ => msg
    }
    let text = match (entry.get("result"), entry.get("error")) {
      (Some(String(result)), _) => "\{msg}: \{result}"
      (_, Some(String(error))) => "\{msg}: \{error}"
      _ => msg
    }
    guard entry.get("errors") is Some(Array(errors)) else { return text }
    let problems = errors.map(error => {
      guard error
        is Object(
          {
            "file": String(file),
            "pointer": String(pointer),
            "message": String(message),
            ..
          }
        ) else {
        return "  not an error: \{error.stringify()}"
      }
      if pointer == "" {
        "  \{file}: \{message}"
      } else {
        "  \{file}: \{pointer}: \{message}"
      }
    })
    [text, ..problems].join("\n")
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
  lines.clear()
  // The same while a problem reading the directory lasts, as this one does
  // whoever runs the test, root included: a body file behind a symlink that
  // leads outside the body-file subdirectory, which "is a problem"
  // (docs/definition-files.md), so each reload reports the set as invalid
  // and logs every error. While it lasts, "each poll reads again"
  // (Reloading): a check that reads it tells that it did not read the
  // directory without problems, as Reloader::check's documentation has it.
  // An Unsure check whose read differs tells that it did, so that the watch
  // keeps the stamp that the quiet period compares with (the same
  // documentation), and "a change of several files made just as such a
  // read begins still gives one reload" (Reloading).
  @fs.write_file("\{dir}/secret.txt", "not a body file")
  @fs.symlink(target="../secret.txt", "\{dir}/files/leak.txt")
  check("Changed, a body file that leads outside files", Changed)
  check("Unsure, nothing changed, the problem lasting", Unsure)
  @fs.write_file("\{dir}/mocks.json", "")
  check("Unsure, mocks.json empty, the problem lasting", Unsure)
  @fs.write_file("\{dir}/mocks.json", renamed)
  run_until_logged(lines, () => reloader.run(watch))
  out.push(
    (
      $|mocks.json written again, the watch's next check: serves \{served()}
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
      #|Changed, a body file that leads outside files: read whole false, serves another set
      #|definitions reload failed: failed
      #|  files/leak.txt: leads outside the body-file subdirectory files, which body files must stay inside
      #|Unsure, nothing changed, the problem lasting: read whole false, serves another set
      #|
      #|Unsure, mocks.json empty, the problem lasting: read whole true, serves another set
      #|
      #|mocks.json written again, the watch's next check: serves another set
      #|definitions reload failed: failed
      #|  files/leak.txt: leads outside the body-file subdirectory files, which body files must stay inside
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
  // The pair of a single Mock beside the default one, for the checks while
  // a problem reading the default pair lasts, below.
  let users_files : @settings.TlsFiles = {
    cert_file: "\{dir}/users.crt",
    key_file: "\{dir}/users.key",
  }
  @fs.write_file(users_files.cert_file, @testcerts.rsa_chain + "\n")
  @fs.write_file(users_files.key_file, @testcerts.rsa_key + "\n")
  // A set that declares the Mock, which is warned about otherwise.
  @fs.mkdir("\{dir}/defs")
  @fs.write_file(
    "\{dir}/defs/mocks.json",
    "{ \"mocks\": [{ \"name\": \"users\" }] }",
  )
  guard @defdir.load(
      Some("\{dir}/defs"),
      body_file_dir="files",
      env=@template.no_env,
    )
    is Ok(snapshot) else {
    fail("the set that declares the Mock users does not load")
  }
  let lines = []
  guard Certificates::load(
      Some(files),
      Map([("users", users_files)]),
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
  guard certificates.by_mock.get("users") is Some(users_pair) else {
    fail("no pair for the Mock users")
  }
  let users_first = users_pair.config
  let watch = blind_watch()
  let presented = () => {
    if physical_equal(pair.config, first) {
      "the first pair"
    } else {
      "another pair"
    }
  }
  let users_presented = () => {
    if physical_equal(users_pair.config, users_first) {
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
  lines.clear()
  // The same for the pair of the Mock users while a problem reading the
  // default pair, which is checked first, lasts, as this one does whoever
  // runs the test, root included: its key deleted. A changed pair "that
  // cannot be used (a file that cannot be read ...) is not swapped in", and
  // one log entry names it (docs/running.md, Rotating certificates); its
  // error is `read_pair`'s and `read_failure`'s, as e2e/certificates_test
  // has it. While the problem lasts, a check tells that it did not read the
  // files of every pair, so that the next poll reads again, as
  // Certificates::check's documentation has it. An Unsure check that finds
  // the files of a pair changed tells that it did, so that the watch keeps
  // the stamp that the quiet period compares with (the same
  // documentation), and "a certificate and its key written less than 250
  // ms apart are loaded together" (Rotating certificates).
  let users_check = async fn(label : String, check : @watch.Check) {
    let read_all = certificates.check(check, watch)
    out.push(
      (
        $|\{label}: read all \{read_all}, presents \{presented()}, and for users \{users_presented()}
        $|\{entries(lines)}
      ),
    )
    lines.clear()
  }
  @fs.remove(files.key_file)
  users_check("Changed, the default key deleted", Changed)
  users_check("Unsure, nothing changed, the problem lasting", Unsure)
  @fs.write_file(users_files.cert_file, "")
  users_check(
    "Unsure, the users certificate empty, the problem lasting",
    Unsure,
  )
  @fs.write_file(users_files.cert_file, @testcerts.ecdsa_chain + "\n")
  users_check(
    "Unsure, the users certificate written, its key not yet, the problem lasting",
    Unsure,
  )
  @fs.write_file(users_files.key_file, @testcerts.ecdsa_key + "\n")
  run_until_logged(lines, () => certificates.run(watch))
  out.push(
    (
      $|both written, the watch's next check: presents \{presented()}, and for users \{users_presented()}
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
      #|Changed, the default key deleted: read all false, presents another pair, and for users the first pair
      #|TLS certificate reload failed: cannot read the key file: no such file
      #|Unsure, nothing changed, the problem lasting: read all false, presents another pair, and for users the first pair
      #|
      #|Unsure, the users certificate empty, the problem lasting: read all true, presents another pair, and for users the first pair
      #|
      #|Unsure, the users certificate written, its key not yet, the problem lasting: read all true, presents another pair, and for users the first pair
      #|
      #|both written, the watch's next check: presents another pair, and for users another pair
      #|TLS certificate reloaded (users)
    ),
  )
}
