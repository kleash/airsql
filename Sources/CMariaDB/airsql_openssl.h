// The four OpenSSL calls AirSQL's TLS check makes (Sources/AirSQLCore/DB/TLSCheck.swift) to read the certificates the
// server sent. libmariadb carries OpenSSL inside and exports them; OpenSSL's own headers stay out of Swift (they need an
// include path and bring thousands of declarations for these four).
struct ssl_st;
struct stack_st;
struct stack_st_X509;
struct x509_st;

struct stack_st_X509 *SSL_get_peer_cert_chain(const struct ssl_st *ssl);
int OPENSSL_sk_num(const struct stack_st *stack);
void *OPENSSL_sk_value(const struct stack_st *stack, int index);
int i2d_X509(const struct x509_st *certificate, unsigned char **out);
