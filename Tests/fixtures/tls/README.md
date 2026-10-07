Test-only TLS fixtures (plan §8, M5): a self-signed identity for the
Swift<->Swift TLS lane. Never use in production. Regenerate with:

  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 36500 -nodes -subj "/CN=capnp-swift-test" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
  openssl pkcs12 -export -out test-identity.p12 -inkey key.pem -in cert.pem \
    -passout pass:capnp-swift-test
  openssl x509 -in cert.pem -outform der -out test-cert.der
  # PKCS#1 (SecKeyCreateWithData rejects openssl 3's default PKCS#8):
  openssl rsa -in key.pem -outform der -traditional -out test-key.der

test-identity.p12 (password: capnp-swift-test) is imported at test time
through SecPKCS12Import (TLSIdentity); test-cert.der is the client-side
pin (TLSTrust.testOnlyTrustThisCertificate). test-key.der (PKCS#1) plus
test-cert.der build the keychain-free identity the QUIC tests use
(TLSIdentity(certificateDER:keyDER:)): a SecPKCS12Import identity used by
the modern QUIC TLS stack stalls on a keychain-authorization prompt,
which never resolves under a headless test runner.
