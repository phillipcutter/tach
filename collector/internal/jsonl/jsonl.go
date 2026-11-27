// Package jsonl holds helpers shared by the line-oriented log sources: reading
// complete lines from an offset, resolving which byte range of a file still needs
// reading, timestamp parsing, account hashing and a bounded worker pool.
package jsonl

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"runtime"
	"sort"
	"sync"
	"syscall"
	"time"

	"tach/collector/internal/cursor"
)

// MaxLine is the longest line the readers will keep. Longer lines (base64 images,
// huge tool outputs) are skipped and counted; they never carry usage we need.
const MaxLine = 64 << 20

// Stats counts what a reader saw. Safe to add from several goroutines via Add.
type Stats struct {
	Lines     int64
	Parsed    int64
	Malformed int64
	Oversized int64
	Bytes     int64
}

func (s *Stats) Add(o Stats) {
	statsMu.Lock()
	s.Lines += o.Lines
	s.Parsed += o.Parsed
	s.Malformed += o.Malformed
	s.Oversized += o.Oversized
	s.Bytes += o.Bytes
	statsMu.Unlock()
}

var statsMu sync.Mutex

// Lines calls fn for every complete ('\n'-terminated) line in r. off is the file
// offset of r's first byte; fn receives each line (without the newline, only valid
// during the call) and that line's start offset. A trailing partial line is not
// passed to fn. Lines returns the offset just past the last complete line.
// If fn returns false, reading stops and Lines returns the offset of that line's end.
//
// If markers is non-nil, a line longer than the 1 MB read buffer whose first
// megabyte holds none of them is skipped without being buffered (every format we
// read puts its record type near the start of the line), and fn never sees it.
func Lines(r io.Reader, off int64, st *Stats, markers [][]byte, fn func(line []byte, at int64) bool) (int64, error) {
	br := bufio.NewReaderSize(r, 1<<20)
	var big []byte // accumulates a line longer than the bufio buffer
	over := false  // current line exceeded MaxLine
	skip := false  // current long line is not wanted
	start := off
	pos := off
	for {
		chunk, err := br.ReadSlice('\n')
		pos += int64(len(chunk))
		if err == bufio.ErrBufferFull {
			if len(big) == 0 && !over && !skip && markers != nil && !ContainsAny(chunk, markers) {
				skip = true
			}
			if !over && !skip {
				if len(big)+len(chunk) > MaxLine {
					over, big = true, big[:0]
				} else {
					big = append(big, chunk...)
				}
			}
			continue
		}
		if err != nil {
			// EOF (or read error) with an unterminated tail: not consumed.
			if err == io.EOF {
				return start, nil
			}
			return start, err
		}
		line := chunk[:len(chunk)-1]
		if skip {
			if st != nil {
				st.Lines++
				st.Bytes += pos - start
			}
			start, skip = pos, false
			continue
		}
		if len(big) > 0 || over {
			if !over && len(big)+len(line) <= MaxLine {
				big = append(big, line...)
				line = big
			} else {
				over = true
			}
		}
		if st != nil {
			st.Lines++
			st.Bytes += pos - start
		}
		if over {
			if st != nil {
				st.Oversized++
			}
		} else if n := len(line); n > 0 && line[n-1] == '\r' {
			line = line[:n-1]
		}
		keep := true
		if !over {
			keep = fn(line, start)
		}
		start = pos
		big, over = big[:0], false
		if cap(big) > 8<<20 {
			big = nil // do not pin a huge buffer for the rest of the file
		}
		if !keep {
			return start, nil
		}
	}
}

// ContainsAny reports whether line contains any of the markers.
func ContainsAny(line []byte, markers [][]byte) bool {
	for _, m := range markers {
		if bytes.Contains(line, m) {
			return true
		}
	}
	return false
}

// Plan is the work for one file in this scan.
type Plan struct {
	Path  string
	Size  int64
	Mtime int64 // unix ms
	Ino   uint64
	From  int64 // offset to start reading at
	Fresh bool  // no usable cursor entry (first sight, truncated or replaced)
}

// Stat returns size, mtime (unix ms) and inode of path.
func Stat(path string) (size, mtime int64, ino uint64, err error) {
	fi, err := os.Stat(path)
	if err != nil {
		return 0, 0, 0, err
	}
	if !fi.Mode().IsRegular() {
		return 0, 0, 0, errors.New("not a regular file")
	}
	if s, ok := fi.Sys().(*syscall.Stat_t); ok {
		ino = uint64(s.Ino)
	}
	return fi.Size(), fi.ModTime().UnixMilli(), ino, nil
}

// PendingGrace is how long an unfinished request at the end of a file holds the
// cursor back. After that the file is re-read once and whatever is there is final.
const PendingGrace = 30 * time.Minute

// PlanFile decides whether and from where a file needs reading. ok is false when
// there is nothing to do: unchanged since the cursor, or (first sight) not modified
// since `since`.
func PlanFile(cur *cursor.State, path string, since, now time.Time) (Plan, bool) {
	size, mtime, ino, err := Stat(path)
	if err != nil {
		return Plan{}, false
	}
	p := Plan{Path: path, Size: size, Mtime: mtime, Ino: ino}
	f, seen := cur.Get(path)
	if seen && (f.Ino != 0 && ino != 0 && f.Ino != ino || size < f.Off || size < f.Size) {
		seen = false // replaced or truncated: start again
	}
	if !seen {
		if mtime < since.UnixMilli() {
			return p, false
		}
		p.Fresh = true
		return p, true
	}
	p.From = f.Off
	if size == f.Size && mtime == f.Mtime {
		// Unchanged. Re-read a held-back tail only once its grace period is over.
		if f.Off >= size || now.UnixMilli()-mtime < PendingGrace.Milliseconds() {
			return p, false
		}
	}
	return p, true
}

// Commit records that p was read up to off.
func Commit(cur *cursor.State, p Plan, off int64) {
	cur.Set(p.Path, cursor.File{Ino: p.Ino, Size: p.Size, Off: off, Mtime: p.Mtime})
}

// ParseTS parses an RFC 3339 timestamp to unix ms; 0 if empty or invalid.
func ParseTS(s string) int64 {
	if s == "" {
		return 0
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return 0
	}
	return t.UnixMilli()
}

// AcctHash is the protocol's account hash: first 12 hex chars of SHA-256.
func AcctHash(id string) string {
	if id == "" {
		return ""
	}
	h := sha256.Sum256([]byte(id))
	return hex.EncodeToString(h[:])[:12]
}

// Parallel runs fn over plans with a bounded pool, largest files first.
func Parallel(plans []Plan, fn func(Plan)) {
	sort.Slice(plans, func(i, j int) bool { return plans[i].Size-plans[i].From > plans[j].Size-plans[j].From })
	n := runtime.GOMAXPROCS(0)
	if n > 12 {
		n = 12
	}
	if n > len(plans) {
		n = len(plans)
	}
	ch := make(chan Plan)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range ch {
				fn(p)
			}
		}()
	}
	for _, p := range plans {
		ch <- p
	}
	close(ch)
	wg.Wait()
}

// Limit thinning: one reading per window per 5 minutes of event time, newest kept.
const ThinStep = 5 * 60 * 1000

// Thin keeps, per key, the newest reading and then every reading at least ThinStep
// older than the last one kept. ts and key give each item's time and window.
func Thin[T any](items []T, key func(T) string, ts func(T) int64) []T {
	sort.SliceStable(items, func(i, j int) bool { return ts(items[i]) > ts(items[j]) })
	last := map[string]int64{}
	out := items[:0:0]
	for _, it := range items {
		k := key(it)
		if l, ok := last[k]; ok && l-ts(it) < ThinStep {
			continue
		}
		last[k] = ts(it)
		out = append(out, it)
	}
	sort.SliceStable(out, func(i, j int) bool { return ts(out[i]) < ts(out[j]) })
	return out
}

// Tail returns up to n bytes from the end of path, starting at a line boundary.
func Tail(path string, n int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	off := fi.Size() - n
	if off < 0 {
		off = 0
	}
	b := make([]byte, fi.Size()-off)
	if _, err := f.ReadAt(b, off); err != nil && err != io.EOF {
		return nil, err
	}
	if off > 0 {
		if i := bytes.IndexByte(b, '\n'); i >= 0 {
			b = b[i+1:]
		} else {
			return nil, nil
		}
	}
	return b, nil
}
