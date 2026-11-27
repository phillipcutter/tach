// Package acct turns provider account ids into the short hashes the collector emits.
package acct

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// Hash returns the first 12 hex chars of SHA-256 of the account id, or "" for an
// empty id. Surrounding whitespace is ignored; case is kept, because ids are
// case-sensitive in general. Use Email for e-mail addresses.
func Hash(id string) string {
	id = strings.TrimSpace(id)
	if id == "" {
		return ""
	}
	s := sha256.Sum256([]byte(id))
	return hex.EncodeToString(s[:])[:12]
}

// Email hashes an e-mail address used as an account id, case-folded so the
// same Google account hashes the same everywhere.
func Email(addr string) string { return Hash(strings.ToLower(strings.TrimSpace(addr))) }
