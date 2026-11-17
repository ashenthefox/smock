// Tests of the reading of a certificate's expiry, which the metric
// `smock_tls_certificate_expiry_timestamp_seconds` reports for each
// certificate the TLS port presents (docs/running.md, "Certificate
// expiry"), and the log entry of each reload gives (docs/running.md,
// "Rotating certificates"): the first CERTIFICATE block of the PEM
// (RFC 7468), the DER walk to the notAfter of its TBSCertificate (RFC 5280,
// section 4.1; X.690), and the time there (RFC 5280, section 4.1.2.5), in
// milliseconds since the Unix epoch. The certificates are the examples of
// RFC 7468, or built here, field by field, as X.690 encodes them. Each
// expected time is the notAfter's date and time, given in seconds since
// the Unix epoch by GNU date (`date -u -d <date> +%s`), and in the RFC's
// examples also printed by `openssl x509 -noout -enddate`.

///|
/// RFC 7468's example of a certificate (section 5.1, Figure 6), whose
/// notAfter is 121222074151Z, 2012-12-22T07:41:51Z, as
/// `openssl x509 -noout -enddate` prints it: 1356162111 seconds since the
/// Unix epoch.
let figure_6 : String =
  #|-----BEGIN CERTIFICATE-----
  #|MIICLDCCAdKgAwIBAgIBADAKBggqhkjOPQQDAjB9MQswCQYDVQQGEwJCRTEPMA0G
  #|A1UEChMGR251VExTMSUwIwYDVQQLExxHbnVUTFMgY2VydGlmaWNhdGUgYXV0aG9y
  #|aXR5MQ8wDQYDVQQIEwZMZXV2ZW4xJTAjBgNVBAMTHEdudVRMUyBjZXJ0aWZpY2F0
  #|ZSBhdXRob3JpdHkwHhcNMTEwNTIzMjAzODIxWhcNMTIxMjIyMDc0MTUxWjB9MQsw
  #|CQYDVQQGEwJCRTEPMA0GA1UEChMGR251VExTMSUwIwYDVQQLExxHbnVUTFMgY2Vy
  #|dGlmaWNhdGUgYXV0aG9yaXR5MQ8wDQYDVQQIEwZMZXV2ZW4xJTAjBgNVBAMTHEdu
  #|dVRMUyBjZXJ0aWZpY2F0ZSBhdXRob3JpdHkwWTATBgcqhkjOPQIBBggqhkjOPQMB
  #|BwNCAARS2I0jiuNn14Y2sSALCX3IybqiIJUvxUpj+oNfzngvj/Niyv2394BWnW4X
  #|uQ4RTEiywK87WRcWMGgJB5kX/t2no0MwQTAPBgNVHRMBAf8EBTADAQH/MA8GA1Ud
  #|DwEB/wQFAwMHBgAwHQYDVR0OBBYEFPC0gf6YEr+1KLlkQAPLzB9mTigDMAoGCCqG
  #|SM49BAMCA0gAMEUCIDGuwD1KPyG+hRf88MeyMQcqOFZD0TbVleF+UsAGQ4enAiEA
  #|l4wOuDwKQa+upc8GftXE2C//4mKANBC6It01gUaTIpo=
  #|-----END CERTIFICATE-----
  #|

///|
/// The octets of `text`, a PEM file whose lines end with LF.
fn pem(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// What the reading gives for `pem`: the expiry, in milliseconds since the
/// Unix epoch, or `None`.
fn expiry(pem : Bytes) -> String {
  match @serverparsers.certificate_expiry(pem) {
    Some(ms) => ms.to_string()
    None => "None"
  }
}

///|
test "a certificate's expiry is its notAfter, in milliseconds since the Unix epoch: RFC 7468's example certificate expires at 2012-12-22T07:41:51Z (RFC 7468, section 5.1, Figure 6; RFC 5280, section 4.1.2.5; docs/running.md, Certificate expiry)" {
  inspect(expiry(pem(figure_6)), content="1356162111000")
}
