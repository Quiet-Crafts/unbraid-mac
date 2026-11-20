// Package main is a small C library (tools/build-kyber.sh builds it as Kyber.xcframework) for the quantum-safe key
// exchange IVPN uses: Round-3 Kyber-1024 from cloudflare/circl, not the final ML-KEM, which IVPN does not accept.
// This file is the plain Go logic; export.go is the C interface.
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"

	"github.com/cloudflare/circl/kem/kyber/kyber1024"
)

// keyPair makes a Round-3 Kyber-1024 key pair and returns "public|private", both base64.
func keyPair() (string, error) {
	pk, sk, err := kyber1024.GenerateKeyPair(rand.Reader)
	if err != nil {
		return "", err
	}
	pkb, err := pk.MarshalBinary()
	if err != nil {
		return "", err
	}
	skb, err := sk.MarshalBinary()
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(pkb) + "|" + base64.StdEncoding.EncodeToString(skb), nil
}

// psk decapsulates a base64 ciphertext with a base64 private key from keyPair and returns base64(SHA-256(shared
// secret)), the WireGuard preshared key.
func psk(private, cipher string) (string, error) {
	skb, err := base64.StdEncoding.DecodeString(private)
	if err != nil || len(skb) != kyber1024.PrivateKeySize {
		return "", errors.New("bad Kyber-1024 private key")
	}
	ct, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(cipher), ""))
	if err != nil || len(ct) != kyber1024.CiphertextSize {
		return "", errors.New("bad Kyber-1024 ciphertext")
	}
	var sk kyber1024.PrivateKey
	sk.Unpack(skb)
	ss := make([]byte, kyber1024.SharedKeySize)
	sk.DecapsulateTo(ss, ct)
	h := sha256.Sum256(ss)
	return base64.StdEncoding.EncodeToString(h[:]), nil
}
