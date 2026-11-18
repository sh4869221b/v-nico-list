#ifndef NICO_NATIVE_TLS_H
#define NICO_NATIVE_TLS_H
#include <mbedtls/ssl.h>
#include <mbedtls/net_sockets.h>

#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#include <wincrypt.h>

/* Mbed TLS checks the hostname and certificate usages. For Windows default
   trust, CryptoAPI verifies the presented chain against the Windows stores
   before any HTTP bytes are sent. Keep issuer retrieval local to the OS cache. */
static int nico_tls_windows_verify(void *context) {
  mbedtls_ssl_context *ssl = (mbedtls_ssl_context *)context;
  const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(ssl);
  if (!peer || (mbedtls_ssl_get_verify_result(ssl) & ~MBEDTLS_X509_BADCERT_NOT_TRUSTED)) {
    return MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
  }

  HCERTSTORE intermediates = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, NULL);
  if (!intermediates) return MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
  PCCERT_CONTEXT leaf = CertCreateCertificateContext(X509_ASN_ENCODING, peer->raw.p,
                                                     (DWORD)peer->raw.len);
  PCCERT_CHAIN_CONTEXT chain = NULL;
  int result = MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
  if (!leaf) goto cleanup;
  for (peer = peer->next; peer; peer = peer->next) {
    if (!CertAddEncodedCertificateToStore(intermediates, X509_ASN_ENCODING, peer->raw.p,
                                         (DWORD)peer->raw.len, CERT_STORE_ADD_ALWAYS, NULL)) {
      goto cleanup;
    }
  }
  LPSTR usage = szOID_PKIX_KP_SERVER_AUTH;
  CERT_CHAIN_PARA params = {0};
  params.cbSize = sizeof(params);
  params.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
  params.RequestedUsage.Usage.cUsageIdentifier = 1;
  params.RequestedUsage.Usage.rgpszUsageIdentifier = &usage;
  if (CertGetCertificateChain(NULL, leaf, NULL, intermediates, &params,
                              CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL, NULL, &chain) &&
      chain->TrustStatus.dwErrorStatus == CERT_TRUST_NO_ERROR) {
    result = 0;
  }

cleanup:
  if (chain) CertFreeCertificateChain(chain);
  if (leaf) CertFreeCertificateContext(leaf);
  CertCloseStore(intermediates, 0);
  return result;
}
#endif

/* V owns the initialized TLS configuration and socket. Replace the I/O
   callbacks so handshake and record reads observe cancellation. */
typedef int (*nico_tls_io)(void *, unsigned char *, size_t);
static int nico_tls_connect(void *context, void *io, const unsigned char *hostname,
                            nico_tls_io send_callback, nico_tls_io recv_callback) {
  mbedtls_ssl_context *ssl = (mbedtls_ssl_context *)context;
  int result = mbedtls_ssl_set_hostname(ssl, (const char *)hostname);
  if (result != 0) return result;
  /* The send adapter reads its buffer; V's pointer type does not express const. */
  mbedtls_ssl_set_bio(ssl, io, (mbedtls_ssl_send_t *)send_callback, recv_callback, NULL);
  do {
    result = mbedtls_ssl_handshake(ssl);
  } while (result == MBEDTLS_ERR_SSL_WANT_READ || result == MBEDTLS_ERR_SSL_WANT_WRITE);
  return result;
}
#endif
