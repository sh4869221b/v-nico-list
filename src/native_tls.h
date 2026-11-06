#ifndef NICO_NATIVE_TLS_H
#define NICO_NATIVE_TLS_H
#include <mbedtls/ssl.h>
#include <mbedtls/net_sockets.h>

/* V owns the initialized TLS configuration, certificate verification and socket.
   Only replace the I/O callbacks so handshake and record reads observe cancel. */
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
