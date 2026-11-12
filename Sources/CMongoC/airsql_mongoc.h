// AirSQL's helper inside libmongoc2 (scripts/build-mongoc.sh): the certificates the server sent on a TLS stream, its
// own first, as DER (malloc'd: free each); how many, or -1 without a finished TLS handshake. OpenSSL stays inside the
// library, so Sources/AirSQLCore/Mongo checks them with SecTrust.
#include <mongoc/mongoc.h>

int airsql_mongoc_peer_chain(mongoc_stream_t *stream, unsigned char **ders, int *lengths, int max);
