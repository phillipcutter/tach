package acct

import "testing"

func TestHash(t *testing.T) {
	// sha256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
	if got := Hash("abc"); got != "ba7816bf8f01" {
		t.Fatalf("Hash(abc) = %q", got)
	}
	if got := Hash("  abc\n"); got != "ba7816bf8f01" {
		t.Fatalf("whitespace not trimmed: %q", got)
	}
	if Hash("") != "" || Hash("   ") != "" {
		t.Fatal("empty id must give empty hash")
	}
	if len(Hash("00000000-0000-0000-0000-000000000000")) != 12 {
		t.Fatal("want 12 hex chars")
	}
	if Email("User@Example.com") != Email("user@example.com ") {
		t.Fatal("Email must case-fold")
	}
	if Hash("A") == Hash("a") {
		t.Fatal("Hash must keep case")
	}
}
