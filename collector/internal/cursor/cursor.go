// Package cursor holds what a scan needs to resume: a byte offset per file plus
// free-form state per source. The app stores it as an opaque string.
package cursor

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"io"
	"sync"
)

type File struct {
	Ino   uint64 `json:"i,omitempty"`
	Size  int64  `json:"s"`
	Off   int64  `json:"o"`
	Mtime int64  `json:"m,omitempty"` // unix ms
}

type State struct {
	mu    sync.Mutex
	V     int               `json:"v"`
	Files map[string]File   `json:"f"`
	KV    map[string]string `json:"kv,omitempty"`
}

func New() *State { return &State{V: 1, Files: map[string]File{}, KV: map[string]string{}} }

func (s *State) Get(path string) (File, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, ok := s.Files[path]
	return f, ok
}
func (s *State) Set(path string, f File) { s.mu.Lock(); s.Files[path] = f; s.mu.Unlock() }
func (s *State) Val(k string) string     { s.mu.Lock(); defer s.mu.Unlock(); return s.KV[k] }
func (s *State) SetVal(k, v string)      { s.mu.Lock(); s.KV[k] = v; s.mu.Unlock() }

// Encode returns base64(gzip(json)).
func (s *State) Encode() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	json.NewEncoder(zw).Encode(s)
	zw.Close()
	return base64.RawURLEncoding.EncodeToString(buf.Bytes())
}

// Decode accepts the output of Encode. An empty or unreadable string gives a fresh state.
func Decode(v string) *State {
	s := New()
	if v == "" {
		return s
	}
	raw, err := base64.RawURLEncoding.DecodeString(v)
	if err != nil {
		return s
	}
	zr, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return s
	}
	b, err := io.ReadAll(zr)
	if err != nil {
		return New()
	}
	t := New()
	if json.Unmarshal(b, t) != nil || t.V != 1 {
		return New()
	}
	if t.Files == nil {
		t.Files = map[string]File{}
	}
	if t.KV == nil {
		t.KV = map[string]string{}
	}
	return t
}
