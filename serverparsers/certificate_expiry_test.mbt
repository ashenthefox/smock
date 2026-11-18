// Tests of the reading of a certificate's expiry, which the metric
// `smock_tls_certificate_expiry_timestamp_seconds` reports for each
// certificate the TLS port presents (docs/running.md, "Certificate
// expiry"), and the log entry of each reload gives (docs/running.md,
// "Rotating certificates"): the first block of the PEM (RFC 7468) that
// OpenSSL loads as the leaf of the TLS port's chain, the DER walk to the notAfter of its TBSCertificate (RFC 5280,
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

///|
/// RFC 7468's example of a certificate with explanatory text before it
/// (section 5.2, Figure 7), whose notAfter is 2013-07-09T03:10:37Z, as the
/// text and `openssl x509 -noout -enddate` give it: 1373339437 seconds
/// since the Unix epoch.
let figure_7 : String =
  #|Subject: CN=Atlantis
  #|Issuer: CN=Atlantis
  #|Validity: from 7/9/2012 3:10:38 AM UTC to 7/9/2013 3:10:37 AM UTC
  #|-----BEGIN CERTIFICATE-----
  #|MIIBmTCCAUegAwIBAgIBKjAJBgUrDgMCHQUAMBMxETAPBgNVBAMTCEF0bGFudGlz
  #|MB4XDTEyMDcwOTAzMTAzOFoXDTEzMDcwOTAzMTAzN1owEzERMA8GA1UEAxMIQXRs
  #|YW50aXMwXDANBgkqhkiG9w0BAQEFAANLADBIAkEAu+BXo+miabDIHHx+yquqzqNh
  #|Ryn/XtkJIIHVcYtHvIX+S1x5ErgMoHehycpoxbErZmVR4GCq1S2diNmRFZCRtQID
  #|AQABo4GJMIGGMAwGA1UdEwEB/wQCMAAwIAYDVR0EAQH/BBYwFDAOMAwGCisGAQQB
  #|gjcCARUDAgeAMB0GA1UdJQQWMBQGCCsGAQUFBwMCBggrBgEFBQcDAzA1BgNVHQEE
  #|LjAsgBA0jOnSSuIHYmnVryHAdywMoRUwEzERMA8GA1UEAxMIQXRsYW50aXOCASow
  #|CQYFKw4DAh0FAANBAKi6HRBaNEL5R0n56nvfclQNaXiDT174uf+lojzA4lhVInc0
  #|ILwpnZ1izL4MlI9eCSHhVQBHEp2uQdXJB+d5Byg=
  #|-----END CERTIFICATE-----
  #|

///|
/// RFC 7468's example of a PKCS #10 certification request (section 7,
/// Figure 9): a CERTIFICATE REQUEST, not a certificate.
let figure_9 : String =
  #|-----BEGIN CERTIFICATE REQUEST-----
  #|MIIBWDCCAQcCAQAwTjELMAkGA1UEBhMCU0UxJzAlBgNVBAoTHlNpbW9uIEpvc2Vm
  #|c3NvbiBEYXRha29uc3VsdCBBQjEWMBQGA1UEAxMNam9zZWZzc29uLm9yZzBOMBAG
  #|ByqGSM49AgEGBSuBBAAhAzoABLLPSkuXY0l66MbxVJ3Mot5FCFuqQfn6dTs+9/CM
  #|EOlSwVej77tj56kj9R/j9Q+LfysX8FO9I5p3oGIwYAYJKoZIhvcNAQkOMVMwUTAY
  #|BgNVHREEETAPgg1qb3NlZnNzb24ub3JnMAwGA1UdEwEB/wQCMAAwDwYDVR0PAQH/
  #|BAUDAwegADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDATAKBggqhkjOPQQDAgM/ADA8
  #|AhxBvfhxPFfbBbsE1NoFmCUczOFApEuQVUw3ZP69AhwWXk3dgSUsKnuwL5g/ftAY
  #|dEQc8B8jAcnuOrfU
  #|-----END CERTIFICATE REQUEST-----
  #|

///|
/// RFC 7468's example of a private key (section 10, Figure 12): a PRIVATE
/// KEY, not a certificate.
let figure_12 : String =
  #|-----BEGIN PRIVATE KEY-----
  #|MIGEAgEAMBAGByqGSM49AgEGBSuBBAAKBG0wawIBAQQgVcB/UNPxalR9zDYAjQIf
  #|jojUDiQuGnSJrFEEzZPT/92hRANCAASc7UJtgnF/abqWM60T3XNJEzBv5ez9TdwK
  #|H0M6xpM2q+53wmsN/eYLdgtjgBd3DBmHtPilCkiFICXyaA8z9LkJ
  #|-----END PRIVATE KEY-----
  #|

///|
/// RFC 7468's example of a certificate with the label of old,
/// "X509 CERTIFICATE" (Appendix A, Figure 16), whose notAfter is
/// 240914061550Z, 2024-09-14T06:15:50Z, as `openssl x509 -noout -enddate`
/// prints it: 1726294550 seconds since the Unix epoch.
let figure_16 : String =
  #|-----BEGIN X509 CERTIFICATE-----
  #|MIIBHDCBxaADAgECAgIcxzAJBgcqhkjOPQQBMBAxDjAMBgNVBAMUBVBLSVghMB4X
  #|DTE0MDkxNDA2MTU1MFoXDTI0MDkxNDA2MTU1MFowEDEOMAwGA1UEAxQFUEtJWCEw
  #|WTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATwoQSr863QrR0PoRIYQ96H7WykDePH
  #|Wa0eVAE24bth43wCNc+U5aZ761dhGhSSJkVWRgVH5+prLIr+nzfIq+X4oxAwDjAM
  #|BgNVHRMBAf8EAjAAMAkGByqGSM49BAEDRwAwRAIfMdKS5F63lMnWVhi7uaKJzKCs
  #|NnY/OKgBex6MIEAv2AIhAI2GdvfL+mGvhyPZE+JxRxWChmggb5/9eHdUcmW/jkOH
  #|-----END X509 CERTIFICATE-----
  #|

///|
/// RFC 7468's example of an attribute certificate (section 12, Figure 14):
/// an ATTRIBUTE CERTIFICATE, an AttributeCertificate of RFC 5755, which
/// holds no notAfter of a certificate.
let figure_14 : String =
  #|-----BEGIN ATTRIBUTE CERTIFICATE-----
  #|MIICKzCCAZQCAQEwgZeggZQwgYmkgYYwgYMxCzAJBgNVBAYTAlVTMREwDwYDVQQI
  #|DAhOZXcgWW9yazEUMBIGA1UEBwwLU3RvbnkgQnJvb2sxDzANBgNVBAoMBkNTRTU5
  #|MjE6MDgGA1UEAwwxU2NvdHQgU3RhbGxlci9lbWFpbEFkZHJlc3M9c3N0YWxsZXJA
  #|aWMuc3VueXNiLmVkdQIGARWrgUUSoIGMMIGJpIGGMIGDMQswCQYDVQQGEwJVUzER
  #|MA8GA1UECAwITmV3IFlvcmsxFDASBgNVBAcMC1N0b255IEJyb29rMQ8wDQYDVQQK
  #|DAZDU0U1OTIxOjA4BgNVBAMMMVNjb3R0IFN0YWxsZXIvZW1haWxBZGRyZXNzPXNz
  #|dGFsbGVyQGljLnN1bnlzYi5lZHUwDQYJKoZIhvcNAQEFBQACBgEVq4FFSjAiGA8z
  #|OTA3MDIwMTA1MDAwMFoYDzM5MTEwMTMxMDUwMDAwWjArMCkGA1UYSDEiMCCGHmh0
  #|dHA6Ly9pZGVyYXNobi5vcmcvaW5kZXguaHRtbDANBgkqhkiG9w0BAQUFAAOBgQAV
  #|M9axFPXXozEFcer06bj9MCBBCQLtAM7ZXcZjcxyva7xCBDmtZXPYUluHf5OcWPJz
  #|5XPus/xS9wBgtlM3fldIKNyNO8RsMp6Ocx+PGlICc7zpZiGmCYLl64lAEGPO/bsw
  #|Smluak1aZIttePeTAHeJJs8izNJ5aR3Wcd3A5gLztQ==
  #|-----END ATTRIBUTE CERTIFICATE-----
  #|

///|
/// RFC 7468's Figure 6 as OpenSSL writes a trusted certificate
/// (`openssl x509 -trustout -addtrust serverAuth`): under the label
/// TRUSTED CERTIFICATE, the certificate, then OpenSSL's trust settings.
/// Its notAfter is Figure 6's, as `openssl x509 -noout -enddate` prints it.
let figure_6_trusted : String =
  #|-----BEGIN TRUSTED CERTIFICATE-----
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
  #|l4wOuDwKQa+upc8GftXE2C//4mKANBC6It01gUaTIpowDDAKBggrBgEFBQcDAQ==
  #|-----END TRUSTED CERTIFICATE-----
  #|

///|
/// `text` with the label `from` of its encapsulation boundaries replaced
/// by `to`.
fn relabel(text : String, from : String, to : String) -> String {
  text
  .replace_all(old="-----BEGIN \{from}-----", new="-----BEGIN \{to}-----")
  .replace_all(old="-----END \{from}-----", new="-----END \{to}-----")
}

///|
/// A UTF-8 byte order mark, U+FEFF, as Windows PowerShell 5.1's
/// `Out-File -Encoding utf8` writes it before the text of a file.
let bom : String = "\u{FEFF}"

///|
test "the expiry is read from the first block that OpenSSL loads as the TLS port's leaf, one labelled CERTIFICATE, X509 CERTIFICATE or TRUSTED CERTIFICATE: after explanatory text and blocks of other labels, an ATTRIBUTE CERTIFICATE and an X.509 CERTIFICATE included, with lines ended by CRLF or by blanks, in a chain the leaf's, which comes first; a byte order mark is dropped where OpenSSL drops one, at the start of the input and right after the END line of a block it skips, and a BEGIN line with white space before it begins no block, as for OpenSSL (RFC 7468, sections 2, 3, 5.1, 5.2, 7, 10 and 12; docs/running.md, HTTPS and Certificate expiry; OpenSSL's PEM_read_bio_X509_AUX)" {
  let figure_16_relabelled = relabel(
    figure_16, "X509 CERTIFICATE", "CERTIFICATE",
  )
  inspect(
    [
      // Section 5.1 allows a parser to read "X509 CERTIFICATE" for backwards
      // compatibility, and OpenSSL's PEM_read_bio_X509_AUX, with which
      // openssl/openssl.c loads the TLS port's chain, reads it: the TLS
      // port presents the certificate, so the metric reports it.
      "X509 CERTIFICATE: \{expiry(pem(figure_16))}",
      // PEM_read_bio_X509_AUX reads a TRUSTED CERTIFICATE too, the
      // certificate and the trust settings after it, and the TLS port
      // presents the certificate.
      "TRUSTED CERTIFICATE: \{expiry(pem(figure_6_trusted))}",
      // Section 12: an ATTRIBUTE CERTIFICATE is an attribute certificate,
      // and section 5.1: parsers SHOULD NOT read "X.509 CERTIFICATE" as
      // "CERTIFICATE". PEM_read_bio_X509_AUX skips both and presents the
      // certificate after them, as a program that calls it on these files
      // prints with OpenSSL 4.1.0: "notAfter Dec 22 07:41:51 2012 GMT". And
      // docs/running.md, Certificate expiry: the metric "gives when each
      // certificate the TLS port presents expires (its notAfter)".
      "an ATTRIBUTE CERTIFICATE first: \{expiry(pem(figure_14 + figure_6))}",
      "an X.509 CERTIFICATE first: \{expiry(pem(relabel(figure_16, "X509 CERTIFICATE", "X.509 CERTIFICATE") + figure_6))}",
      // Section 5.2: tools emit explanatory text before the BEGIN line, and
      // section 2: "Data before the encapsulation boundaries are permitted".
      "explanatory text before: \{expiry(pem(figure_7))}",
      // Section 2: parsers "MUST handle different newline conventions".
      "CRLF: \{expiry(pem(figure_6.replace_all(old="\n", new="\r\n")))}",
      // Section 3, Figure 1: blanks (WSP) may end each line.
      "blanks at the ends of lines: \{expiry(pem(figure_6.replace_all(old="\n", new=" \t\n")))}",
      // Sections 7 and 10: a CERTIFICATE REQUEST and a PRIVATE KEY are other
      // types of data.
      "a key and a request first: \{expiry(pem(figure_12 + figure_9 + figure_6))}",
      // docs/running.md, HTTPS: "The certificate file holds the leaf
      // certificate, then its intermediate certificates".
      "leaf of 2012, then 2024: \{expiry(pem(figure_6 + figure_16_relabelled))}",
      "leaf of 2024, then 2012: \{expiry(pem(figure_16_relabelled + figure_6))}",
      // OpenSSL's PEM_read_bio_X509_AUX reads one block at a time, each with
      // PEM_read_bio_ex, until it reads a certificate, and each such read
      // drops a UTF-8 byte order mark from the first line it takes
      // (crypto/pem/pem_lib.c, get_name and sanitize_line): the first line
      // of the input, and the line right after the END line of a block it
      // skips. A program that calls it on each of the next four files
      // prints with OpenSSL 4.1.0 the leaf of 2012, "notAfter Dec 22
      // 07:41:51 2012 GMT": the TLS port presents it, so the metric
      // reports it.
      "a byte order mark first, in a chain: \{expiry(pem(bom + figure_6 + figure_16_relabelled))}",
      "a byte order mark first, a certificate alone: \{expiry(pem(bom + figure_6))}",
      "a byte order mark right after a PRIVATE KEY: \{expiry(pem(figure_12 + bom + figure_6 + figure_16_relabelled))}",
      "a byte order mark first and right after a PRIVATE KEY: \{expiry(pem(bom + figure_12 + bom + figure_6 + figure_16_relabelled))}",
      // On any other line the mark stays, and a line that starts with it is
      // not a BEGIN line: after a blank line, after explanatory text, after
      // an END line that ends no block, or after a mark already dropped.
      // OpenSSL 4.1.0 then skips the leaf and presents the certificate of
      // 2024 after it, "notAfter Sep 14 06:15:50 2024 GMT".
      "a blank line, then a byte order mark, after a PRIVATE KEY: \{expiry(pem(figure_12 + "\n" + bom + figure_6 + figure_16_relabelled))}",
      "explanatory text, then a byte order mark: \{expiry(pem("Subject: x\n" + bom + figure_6 + figure_16_relabelled))}",
      "an END line that ends no block, then a byte order mark: \{expiry(pem("-----END PRIVATE KEY-----\n" + bom + figure_6 + figure_16_relabelled))}",
      "two byte order marks first: \{expiry(pem(bom + bom + figure_6 + figure_16_relabelled))}",
      // get_name takes a line for a BEGIN line only when it starts with
      // "-----BEGIN ": white space before it makes it no BEGIN line, so
      // OpenSSL 4.1.0 skips the leaf and presents the certificate of 2024
      // after it, also when a mark dropped comes before the white space. A
      // block of another label whose BEGIN line has white space before it
      // is no block either, so the line after its END line keeps its mark.
      "a blank before the leaf's BEGIN line: \{expiry(pem(" " + figure_6 + figure_16_relabelled))}",
      "a tab before the leaf's BEGIN line: \{expiry(pem("\t" + figure_6 + figure_16_relabelled))}",
      "a byte order mark and a blank before the leaf's BEGIN line: \{expiry(pem(bom + " " + figure_6 + figure_16_relabelled))}",
      "a blank before a PRIVATE KEY's BEGIN line, then a byte order mark: \{expiry(pem(" " + figure_12 + bom + figure_6 + figure_16_relabelled))}",
      // With no certificate after it, OpenSSL 4.1.0 loads none: "no start
      // line".
      "a blank before the BEGIN line of a certificate alone: \{expiry(pem(" " + figure_6))}",
      // In the certificate's block, OpenSSL takes a line with white space
      // before its END for a line of base64, and its decoder stops at the
      // first "-" (EVP_DecodeUpdate): with the END line of the next
      // certificate after it, OpenSSL 4.1.0 presents the leaf of 2012.
      "a blank before the leaf's END line, in a chain: \{expiry(pem(figure_6.replace_all(old="-----END", new=" -----END") + figure_16_relabelled))}",
    ].join("\n"),
    content=(
      #|X509 CERTIFICATE: 1726294550000
      #|TRUSTED CERTIFICATE: 1356162111000
      #|an ATTRIBUTE CERTIFICATE first: 1356162111000
      #|an X.509 CERTIFICATE first: 1356162111000
      #|explanatory text before: 1373339437000
      #|CRLF: 1356162111000
      #|blanks at the ends of lines: 1356162111000
      #|a key and a request first: 1356162111000
      #|leaf of 2012, then 2024: 1356162111000
      #|leaf of 2024, then 2012: 1726294550000
      #|a byte order mark first, in a chain: 1356162111000
      #|a byte order mark first, a certificate alone: 1356162111000
      #|a byte order mark right after a PRIVATE KEY: 1356162111000
      #|a byte order mark first and right after a PRIVATE KEY: 1356162111000
      #|a blank line, then a byte order mark, after a PRIVATE KEY: 1726294550000
      #|explanatory text, then a byte order mark: 1726294550000
      #|an END line that ends no block, then a byte order mark: 1726294550000
      #|two byte order marks first: 1726294550000
      #|a blank before the leaf's BEGIN line: 1726294550000
      #|a tab before the leaf's BEGIN line: 1726294550000
      #|a byte order mark and a blank before the leaf's BEGIN line: 1726294550000
      #|a blank before a PRIVATE KEY's BEGIN line, then a byte order mark: 1726294550000
      #|a blank before the BEGIN line of a certificate alone: None
      #|a blank before the leaf's END line, in a chain: 1356162111000
    ),
  )
}

///|
/// The DER encoding of an element with the identifier octet `tag` and the
/// contents `contents`: its length in the short form below 128 octets, and
/// from 128 in the long form, in the fewest octets (X.690, sections 8.1.3
/// and 10.1).
fn der(tag : Int32, contents : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  out.write_byte(tag.to_byte())
  let n = contents.length()
  if n < 0x80 {
    out.write_byte(n.to_byte())
  } else {
    let octets = []
    let mut rest = n
    while rest > 0 {
      octets.push((rest & 0xff).to_byte())
      rest = rest >> 8
    }
    out.write_byte((0x80 + octets.length()).to_byte())
    for i = octets.length() - 1; i >= 0; i = i - 1 {
      out.write_byte(octets[i])
    }
  }
  out.write_bytes(contents)
  out.to_bytes()
}

///|
/// The DER encoding of a time: a UTCTime (tag 23) or a GeneralizedTime
/// (tag 24) whose text is `text` (X.690, sections 8.25, 8.26, 11.7 and
/// 11.8).
fn time(tag : Int32, text : String) -> Bytes {
  der(tag, @utf8.encode(text))
}

///|
/// A UTCTime of `text`.
fn utc(text : String) -> Bytes {
  time(0x17, text)
}

///|
/// A GeneralizedTime of `text`.
fn generalized(text : String) -> Bytes {
  time(0x18, text)
}

///|
/// The DER encoding of a Name of one RDN, the commonName `name` (RFC 5280,
/// section 4.1.2.4).
fn name(name : String) -> Bytes {
  let common_name = der(0x06, b"\x55\x04\x03") + der(0x0c, @utf8.encode(name))
  der(0x30, der(0x31, der(0x30, common_name)))
}

///|
/// ecdsa-with-SHA256 as an AlgorithmIdentifier (RFC 5758, section 3.2).
let ecdsa_with_sha256 : Bytes = der(
  0x30,
  der(0x06, b"\x2a\x86\x48\xce\x3d\x04\x03\x02"),
)

///|
/// The contents of the DER encoding of a certificate whose Validity is
/// `validity`, a SEQUENCE's contents (RFC 5280, section 4.1): the
/// Certificate's three fields, its TBSCertificate's version when `version`
/// is 2 (v3) and left out for v1, which is its default (X.690, section
/// 11.5), a serial number, the issuer `issuer`, and a signature of
/// `signature` octets. The subject's key and what follows it are left
/// out: nothing after the Validity is read.
fn certificate_contents(
  validity : Bytes,
  version~ : Int32 = 2,
  issuer~ : String = "smock",
  signature~ : Int32 = 64,
) -> Bytes {
  let version = match version {
    2 => der(0xa0, der(0x02, b"\x02"))
    _ => b""
  }
  let tbs = der(
    0x30,
    version +
    der(0x02, b"\x01") +
    ecdsa_with_sha256 +
    name(issuer) +
    der(0x30, validity) +
    name(issuer),
  )
  tbs + ecdsa_with_sha256 + der(0x03, Bytes::make(signature + 1, b'\x00'))
}

///|
/// The DER encoding of the certificate whose contents
/// `certificate_contents` gives.
fn certificate(
  validity : Bytes,
  version~ : Int32 = 2,
  issuer~ : String = "smock",
  signature~ : Int32 = 64,
) -> Bytes {
  der(0x30, certificate_contents(validity, version~, issuer~, signature~))
}

///|
/// The octets of a PEM file of the certificate `der`, under the label
/// CERTIFICATE, its base64 in lines of 64 characters (RFC 7468, sections 2
/// and 5.1).
fn pem_of(der : Bytes) -> Bytes {
  let base64 = @base64.encode(der)
  let lines = ["-----BEGIN CERTIFICATE-----"]
  for start = 0; start < base64.length(); start = start + 64 {
    let end = if start + 64 < base64.length() {
      start + 64
    } else {
      base64.length()
    }
    lines.push(base64[start:end].to_owned())
  }
  lines.push("-----END CERTIFICATE-----")
  pem(lines.map(line => line + "\n").join(""))
}

///|
/// A PEM of a certificate whose notBefore is 2000-01-01T00:00:00Z and
/// whose notAfter is `not_after`, an encoded element.
fn with_not_after(not_after : Bytes) -> Bytes {
  pem_of(certificate(utc("000101000000Z") + not_after))
}

///|
test "a notAfter at the ends of the ranges of RFC 5280: a UTCTime year of 50 or more is 19YY, below 50 20YY, from 1950-01-01T00:00:00Z to 2049-12-31T23:59:59Z, then a GeneralizedTime from 2050 up to 99991231235959Z, the notAfter of a certificate with no well-defined expiration date (RFC 5280, sections 4.1.2.5, 4.1.2.5.1 and 4.1.2.5.2)" {
  let read = (not_after : Bytes) => expiry(with_not_after(not_after))
  inspect(
    [
      "UTCTime 500101000000Z: \{read(utc("500101000000Z"))}",
      "UTCTime 991231235959Z: \{read(utc("991231235959Z"))}",
      "UTCTime 000101000000Z: \{read(utc("000101000000Z"))}",
      "UTCTime 491231235959Z: \{read(utc("491231235959Z"))}",
      // "Conforming applications MUST be able to process validity dates that
      // are encoded in either UTCTime or GeneralizedTime."
      "GeneralizedTime 20491231235959Z: \{read(generalized("20491231235959Z"))}",
      "GeneralizedTime 20500101000000Z: \{read(generalized("20500101000000Z"))}",
      "GeneralizedTime 99991231235959Z: \{read(generalized("99991231235959Z"))}",
    ].join("\n"),
    content=(
      #|UTCTime 500101000000Z: -631152000000
      #|UTCTime 991231235959Z: 946684799000
      #|UTCTime 000101000000Z: 946684800000
      #|UTCTime 491231235959Z: 2524607999000
      #|GeneralizedTime 20491231235959Z: 2524607999000
      #|GeneralizedTime 20500101000000Z: 2524608000000
      #|GeneralizedTime 99991231235959Z: 253402300799000
    ),
  )
}

///|
test "the walk to the notAfter reads a v1 certificate, which leaves out its version, as a v3 one, and lengths in the long form of one, two and three octets (RFC 5280, section 4.1: version DEFAULT v1; X.690, sections 8.1.3, 10.1 and 11.5)" {
  let validity = utc("000101000000Z") + generalized("99991231235959Z")
  // An issuer whose commonName has `issuer` characters, and a signature of
  // 70,000 octets: the issuer's lengths take the long form, of one octet
  // for 200 characters and of two for 300, before the Validity, and the
  // Certificate's length takes three.
  let long = (version : Int32, issuer : Int32) => {
    expiry(
      pem_of(
        certificate(
          validity,
          version~,
          issuer="x".repeat(issuer),
          signature=70000,
        ),
      ),
    )
  }
  inspect(
    [
      "v3: \{expiry(pem_of(certificate(validity)))}",
      "v1: \{expiry(pem_of(certificate(validity, version=1)))}",
      "v3, an issuer of 200: \{long(2, 200)}",
      "v3, an issuer of 300: \{long(2, 300)}",
      "v1, an issuer of 300: \{long(1, 300)}",
    ].join("\n"),
    content=(
      #|v3: 253402300799000
      #|v1: 253402300799000
      #|v3, an issuer of 200: 253402300799000
      #|v3, an issuer of 300: 253402300799000
      #|v1, an issuer of 300: 253402300799000
    ),
  )
}

///|
/// The contents of a TBSCertificate up to its issuer: a v3 version, a
/// serial number, its signature's algorithm and the issuer (RFC 5280,
/// section 4.1).
fn tbs_head() -> Bytes {
  der(0xa0, der(0x02, b"\x02")) +
  der(0x02, b"\x01") +
  ecdsa_with_sha256 +
  name("smock")
}

///|
/// A PEM of the certificate whose TBSCertificate's contents are `tbs`.
fn pem_of_tbs(tbs : Bytes) -> Bytes {
  pem_of(der(0x30, der(0x30, tbs) + ecdsa_with_sha256 + der(0x03, b"\x00")))
}

///|
test "no expiry when the PEM holds no certificate, or a certificate whose encoding is malformed or whose notAfter is not a UTCTime or GeneralizedTime of RFC 5280's form, or not a date (RFC 7468; X.690, sections 8.1.2, 8.1.3, 10.1, 11.7 and 11.8; RFC 5280, sections 4.1, 4.1.2.5.1 and 4.1.2.5.2; docs/running.md, Rotating certificates: expiry null, and Certificate expiry: the series gives 0)" {
  let not_before = utc("000101000000Z")
  let contents = certificate_contents(not_before + utc("491231235959Z"))
  let good = der(0x30, contents)
  let cases = [
    // RFC 7468: no block, or the block of a key alone.
    ("nothing", b""),
    ("a PRIVATE KEY alone", pem(figure_12)),
    // RFC 7468, section 2: a block ends with its END line.
    (
      "no END line",
      pem(figure_6.replace_all(old="-----END CERTIFICATE-----\n", new="")),
    ),
    // RFC 4648, sections 3.5 and 4: the base64 cut short, so that its last
    // two characters set bits past the octets they encode.
    ("base64 cut short", pem(figure_6.replace_all(old="Ipo=\n", new="Ip\n"))),
    ("no octets", pem_of(b"")),
    // X.690, section 8.1.2 and 8.1.3: an identifier octet, then length
    // octets.
    ("one octet", pem_of(b"\x30")),
    // RFC 5280, section 4.1: a Certificate and a TBSCertificate are
    // SEQUENCEs (tag 0x30).
    ("a SET for the Certificate", pem_of(der(0x31, contents))),
    (
      "a SET for the TBSCertificate",
      pem_of(der(0x30, der(0x31, tbs_head()) + ecdsa_with_sha256)),
    ),
    // X.690, section 8.1.3: the contents are as long as the length says.
    ("the last octet cut", pem_of(good[:good.length() - 1].to_owned())),
    // X.690, section 10.1: DER's lengths are definite, and section
    // 8.1.3.5: the long form's first octet 0xff "shall not be used".
    ("an indefinite length", pem_of(b"\x30\x80" + contents + b"\x00\x00")),
    ("the length octet 0xff", pem_of(b"\x30\xff" + contents)),
    // X.690, section 8.1.3.2: a primitive element's length is definite. The
    // serial number's would take in the signature's algorithm, the issuer
    // and the Validity.
    (
      "a serial number of indefinite length",
      pem_of_tbs(
        der(0xa0, der(0x02, b"\x02")) +
        b"\x02\x80" +
        ecdsa_with_sha256 +
        name("smock") +
        der(0x30, not_before + utc("491231235959Z")) +
        b"\x00\x00",
      ),
    ),
    // X.690, section 8.1.3.5: the long form's octets follow its first.
    ("the long form cut", pem_of(b"\x30\x82\x01")),
    // RFC 5280, section 4.1: a serial number, the signature's algorithm and
    // the issuer come first; the Validity follows them, and is a SEQUENCE
    // of notBefore and notAfter.
    ("an empty TBSCertificate", pem_of_tbs(b"")),
    (
      "nothing after the serial number",
      pem_of_tbs(der(0xa0, der(0x02, b"\x02")) + der(0x02, b"\x01")),
    ),
    ("nothing after the issuer", pem_of_tbs(tbs_head())),
    (
      "a SET for the Validity",
      pem_of_tbs(tbs_head() + der(0x31, not_before + not_before)),
    ),
    ("no notAfter", pem_of_tbs(tbs_head() + der(0x30, not_before))),
    // RFC 5280, section 4.1.2.5: a time is a UTCTime (tag 23) or a
    // GeneralizedTime (tag 24).
    ("a UTF8String", with_not_after(der(0x0c, b"491231235959Z"))),
    // Sections 4.1.2.5.1 and 4.1.2.5.2: YYMMDDHHMMSSZ in a UTCTime,
    // YYYYMMDDHHMMSSZ in a GeneralizedTime, in GMT, with seconds and no
    // fraction.
    (
      "a UTCTime of four digits for the year",
      with_not_after(utc("20491231235959Z")),
    ),
    ("a GeneralizedTime of two", with_not_after(generalized("491231235959Z"))),
    ("no seconds", with_not_after(utc("4912312359Z"))),
    ("a fraction", with_not_after(generalized("20500101000000.5Z"))),
    ("a differential", with_not_after(utc("491231235959+0000"))),
    ("z for Z", with_not_after(utc("491231235959z"))),
    ("a letter for a digit", with_not_after(utc("49I231235959Z"))),
    // Section 4.1.2.5: the notAfter is a date.
    ("month 13", with_not_after(utc("491301000000Z"))),
    ("February 30", with_not_after(generalized("20500230000000Z"))),
  ]
  inspect(
    cases.map(case => "\{case.0}: \{expiry(case.1)}").join("\n"),
    content=(
      #|nothing: None
      #|a PRIVATE KEY alone: None
      #|no END line: None
      #|base64 cut short: None
      #|no octets: None
      #|one octet: None
      #|a SET for the Certificate: None
      #|a SET for the TBSCertificate: None
      #|the last octet cut: None
      #|an indefinite length: None
      #|the length octet 0xff: None
      #|a serial number of indefinite length: None
      #|the long form cut: None
      #|an empty TBSCertificate: None
      #|nothing after the serial number: None
      #|nothing after the issuer: None
      #|a SET for the Validity: None
      #|no notAfter: None
      #|a UTF8String: None
      #|a UTCTime of four digits for the year: None
      #|a GeneralizedTime of two: None
      #|no seconds: None
      #|a fraction: None
      #|a differential: None
      #|z for Z: None
      #|a letter for a digit: None
      #|month 13: None
      #|February 30: None
    ),
  )
}
