package main

import (
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"

	"github.com/cloudflare/circl/kem/kyber/kyber1024"
)

func TestKyberRoundTrip(t *testing.T) {
	pair, err := keyPair()
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(pair, "|")
	pkb, _ := base64.StdEncoding.DecodeString(parts[0])
	var pk kyber1024.PublicKey
	pk.Unpack(pkb)
	ct := make([]byte, kyber1024.CiphertextSize)
	ss := make([]byte, kyber1024.SharedKeySize)
	pk.EncapsulateTo(ct, ss, nil)
	got, err := psk(parts[1], base64.StdEncoding.EncodeToString(ct))
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(ss)
	if got != base64.StdEncoding.EncodeToString(h[:]) {
		t.Fatal("psk mismatch")
	}
	if _, err := psk(parts[1], "AAAA"); err == nil {
		t.Fatal("bad ciphertext accepted")
	}
	if _, err := psk("AAAA", base64.StdEncoding.EncodeToString(ct)); err == nil {
		t.Fatal("bad private key accepted")
	}
}
