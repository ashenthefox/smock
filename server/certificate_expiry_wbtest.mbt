// The expiry metric through the checks of the certificates: the series of
// `smock_tls_certificate_expiry_timestamp_seconds` that a pair has once it
// is loaded at startup, swapped in by a rotation, or kept by a failed reload
// (docs/running.md, Certificate expiry and Rotating certificates). Each
// check here is `Changed`, as when a change has settled. The expected times
// are the test leaves' notAfter, as @testcerts gives it, in seconds since
// the Unix epoch by GNU date (`date -u -d <date> +%s`).

///|
/// `@testcerts.ecdsa_chain` with the notAfter of its leaf, the
/// GeneralizedTime 21250101000000Z, ending in a lower-case z: not a time in
/// RFC 5280's form (section 4.1.2.5.2), so smock cannot read it, while
/// OpenSSL still loads the certificate (`openssl x509 -noout -enddate`
/// prints "notAfter=Bad time value"). In the leaf's base64,
/// "MjEyNTAxMDEwMDAwMDBa" holds those 15 characters, three to each four, so
/// "MDB6" in place of its last four gives "00z".
fn unreadable_expiry_chain() -> String raise {
  let chain = @testcerts.ecdsa_chain.replace(
    old="MjEyNTAxMDEwMDAwMDBa",
    new="MjEyNTAxMDEwMDAwMDB6",
  )
  guard chain != @testcerts.ecdsa_chain else {
    fail("the leaf's notAfter is not where it was")
  }
  chain
}

///|
/// The message of each log entry in `lines`, with the expiry it gives, if
/// any, one entry a line.
fn expiry_entries(lines : Array[String]) -> String {
  lines
  .map(line => {
    let parsed = Some(@json.parse(line)) catch { _ => None }
    guard parsed is Some(Object(entry)) && entry.get("msg") is Some(String(msg)) else {
      return "not a log entry: \{line}"
    }
    match entry.get("expiry") {
      Some(expiry) => "\{msg}, expiry \{expiry.stringify()}"
      None => msg
    }
  })
  .join("\n")
}

///|
async test "a rotation to a certificate whose notAfter smock cannot read sets its series of the expiry metric to 0, as at startup, and a failed reload keeps the series of the certificate smock keeps presenting (docs/running.md, Certificate expiry)" {
  // docs/running.md, Certificate expiry: when smock cannot read the
  // notAfter of a certificate it loads at startup, "the certificate's
  // series gives 0. A rotation to such a certificate sets the series to 0
  // too, and the reload's log entry gives `"expiry":null`", as the
  // maintainer decided on 2026-11-18 (#385). "A failed reload keeps the
  // previous certificate, and the series keeps its notAfter." Rotating
  // certificates: one log entry gives "the new certificate's expiry".
  let dir = @fs.tmpdir(prefix="smock-certificates-")
  defer @fs.rmdir(dir, recursive=true)
  let files : @settings.TlsFiles = {
    cert_file: "\{dir}/tls.crt",
    key_file: "\{dir}/tls.key",
  }
  let unreadable = unreadable_expiry_chain()
  @fs.write_file(files.cert_file, unreadable + "\n")
  @fs.write_file(files.key_file, @testcerts.ecdsa_key + "\n")
  guard @defdir.load(None, body_file_dir="files", env=@template.no_env)
    is Ok(snapshot) else {
    fail("the empty set does not load")
  }
  let lines = []
  let metrics = @metrics.Registry()
  guard Certificates::load(
      Some(files),
      Map([]),
      alpn=["http/1.1"],
      engine=@engine.Engine(snapshot),
      logger=@log.Logger(write_line=line => lines.push(line), now=() => 0),
      metrics~,
    )
    is Some(certificates) else {
    fail("the first pair does not load: \{lines.join("\n")}")
  }
  let series = () => {
    metrics
    .render()
    .split("\n")
    .filter(line => {
      line.has_prefix("smock_tls_certificate_expiry_timestamp_seconds{")
    })
    .map(line => line.to_owned())
    .join("\n")
  }
  let out = [
    (
      $|startup, a certificate whose notAfter smock cannot read:
      $|\{series()}
    ),
  ]
  lines.clear()
  let watch = blind_watch()
  let step = async fn(label : String) {
    let _ = certificates.check(Changed, watch)
    out.push(
      (
        $|\{label}:
        $|\{expiry_entries(lines)}
        $|\{series()}
      ),
    )
    lines.clear()
  }
  @fs.write_file(files.cert_file, @testcerts.rsa_chain + "\n")
  @fs.write_file(files.key_file, @testcerts.rsa_key + "\n")
  step("a rotation to smock-test-rsa")
  // Rotating certificates: a file that "holds no usable PEM" is not swapped
  // in.
  @fs.write_file(files.cert_file, "not PEM\n")
  step("a certificate file that is not PEM, a failed reload")
  @fs.write_file(files.cert_file, unreadable + "\n")
  @fs.write_file(files.key_file, @testcerts.ecdsa_key + "\n")
  step("a rotation back to the certificate whose notAfter smock cannot read")
  @fs.write_file(files.cert_file, @testcerts.ecdsa_chain + "\n")
  step("a rotation to smock-test-ecdsa, with the same key")
  inspect(
    out.join("\n"),
    content=(
      #|startup, a certificate whose notAfter smock cannot read:
      #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 0
      #|a rotation to smock-test-rsa:
      #|TLS certificate reloaded, expiry "2126-01-01T00:00:00.000Z"
      #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4922899200
      #|a certificate file that is not PEM, a failed reload:
      #|TLS certificate reload failed, expiry null
      #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4922899200
      #|a rotation back to the certificate whose notAfter smock cannot read:
      #|TLS certificate reloaded, expiry null
      #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 0
      #|a rotation to smock-test-ecdsa, with the same key:
      #|TLS certificate reloaded, expiry "2125-01-01T00:00:00.000Z"
      #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4891363200
    ),
  )
}
