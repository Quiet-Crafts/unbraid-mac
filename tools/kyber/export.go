package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"

import "unsafe"

// The C interface, declared in headers/unbraid_kyber.h of the framework (tools/build-kyber.sh). Strings come back as
// malloc'd C strings: free them with unbraid_kyber_free.

// reply hands a Go string to C. An empty one is still a valid, empty C string.
func reply(s string) *C.char { return C.CString(s) }

//export unbraid_kyber_keypair
func unbraid_kyber_keypair(out **C.char) C.int {
	pair, err := keyPair()
	if err != nil {
		*out = reply(err.Error())
		return 1
	}
	*out = reply(pair)
	return 0
}

//export unbraid_kyber_psk
func unbraid_kyber_psk(private, cipher *C.char, out **C.char) C.int {
	key, err := psk(C.GoString(private), C.GoString(cipher))
	if err != nil {
		*out = reply(err.Error())
		return 1
	}
	*out = reply(key)
	return 0
}

//export unbraid_kyber_free
func unbraid_kyber_free(p *C.char) {
	if p == nil {
		return
	}
	// A result may hold a private key: wipe it before it goes back.
	C.memset(unsafe.Pointer(p), 0, C.strlen(p))
	C.free(unsafe.Pointer(p))
}

func main() {}
