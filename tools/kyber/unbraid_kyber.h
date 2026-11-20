#ifndef UNBRAID_KYBER_H
#define UNBRAID_KYBER_H

/* Round-3 Kyber-1024 (the variant IVPN's quantum-safe key exchange uses, not the final ML-KEM), from cloudflare/circl.
   Both functions return 0 and set *out to a result, or return 1 and set *out to an error message. Every *out is a
   malloc'd C string that the caller frees with unbraid_kyber_free, which wipes it first (a result can be a private key). */

/* A new key pair, as "public|private", both base64. */
int unbraid_kyber_keypair(char **out);

/* The WireGuard preshared key for a base64 ciphertext and a base64 private key from unbraid_kyber_keypair:
   base64(SHA-256(decapsulated secret)). */
int unbraid_kyber_psk(const char *private_key, const char *cipher, char **out);

void unbraid_kyber_free(char *p);

#endif
