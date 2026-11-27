// Package pb is a minimal protobuf wire-format reader. It decodes a message into
// its fields by number, without a schema, so callers can pick out the few fields
// they need from blobs whose .proto files are not public.
package pb

import (
	"errors"
	"strconv"
)

// Wire types.
const (
	Varint  = 0
	Fixed64 = 1
	Bytes   = 2
	Fixed32 = 5
)

// Field is one decoded field. V holds varint and fixed values; B holds the
// payload of a length-delimited field (a sub-slice of the input, not a copy).
type Field struct {
	Num  int
	Type int
	V    uint64
	B    []byte
}

// Msg is a decoded message: its fields in wire order. Repeated fields appear
// once per occurrence.
type Msg []Field

var (
	ErrTruncated = errors.New("pb: truncated")
	ErrOverflow  = errors.New("pb: varint overflow")
	ErrWireType  = errors.New("pb: unsupported wire type")
	ErrFieldNum  = errors.New("pb: invalid field number")
)

func varint(b []byte, i int) (uint64, int, error) {
	var r uint64
	for s := uint(0); ; s += 7 {
		if i >= len(b) {
			return 0, i, ErrTruncated
		}
		if s >= 64 {
			return 0, i, ErrOverflow
		}
		c := b[i]
		i++
		r |= uint64(c&0x7f) << s
		if c < 0x80 {
			return r, i, nil
		}
	}
}

// Parse decodes one message. Groups (wire types 3 and 4) are rejected.
func Parse(b []byte) (Msg, error) {
	var m Msg
	for i := 0; i < len(b); {
		k, j, err := varint(b, i)
		if err != nil {
			return nil, err
		}
		i = j
		f := Field{Num: int(k >> 3), Type: int(k & 7)}
		if f.Num <= 0 || k>>3 > 1<<29-1 {
			return nil, ErrFieldNum
		}
		switch f.Type {
		case Varint:
			f.V, i, err = varint(b, i)
			if err != nil {
				return nil, err
			}
		case Fixed64:
			if i+8 > len(b) {
				return nil, ErrTruncated
			}
			for n := 0; n < 8; n++ {
				f.V |= uint64(b[i+n]) << (8 * n)
			}
			i += 8
		case Fixed32:
			if i+4 > len(b) {
				return nil, ErrTruncated
			}
			for n := 0; n < 4; n++ {
				f.V |= uint64(b[i+n]) << (8 * n)
			}
			i += 4
		case Bytes:
			var l uint64
			l, i, err = varint(b, i)
			if err != nil {
				return nil, err
			}
			if l > uint64(len(b)-i) {
				return nil, ErrTruncated
			}
			f.B = b[i : i+int(l)]
			i += int(l)
		default:
			return nil, ErrWireType
		}
		m = append(m, f)
	}
	return m, nil
}

// Last returns the last occurrence of field n (proto3 "last one wins").
func (m Msg) Last(n int) (Field, bool) {
	for i := len(m) - 1; i >= 0; i-- {
		if m[i].Num == n {
			return m[i], true
		}
	}
	return Field{}, false
}

// All returns every occurrence of field n.
func (m Msg) All(n int) []Field {
	var r []Field
	for _, f := range m {
		if f.Num == n {
			r = append(r, f)
		}
	}
	return r
}

// Has reports whether field n is present.
func (m Msg) Has(n int) bool { _, ok := m.Last(n); return ok }

// Uint returns varint field n, or 0.
func (m Msg) Uint(n int) uint64 {
	if f, ok := m.Last(n); ok && f.Type == Varint {
		return f.V
	}
	return 0
}

// Int returns varint field n as int64, or 0.
func (m Msg) Int(n int) int64 { return int64(m.Uint(n)) }

// Bytes returns length-delimited field n, or nil.
func (m Msg) Bytes(n int) []byte {
	if f, ok := m.Last(n); ok && f.Type == Bytes {
		return f.B
	}
	return nil
}

// Str returns length-delimited field n as a string, or "".
func (m Msg) Str(n int) string { return string(m.Bytes(n)) }

// Sub decodes length-delimited field n as a message. A missing or undecodable
// field gives nil, false.
func (m Msg) Sub(n int) (Msg, bool) {
	f, ok := m.Last(n)
	if !ok || f.Type != Bytes {
		return nil, false
	}
	s, err := Parse(f.B)
	if err != nil {
		return nil, false
	}
	return s, true
}

// Path follows nested message fields, e.g. Path(1, 4) is field 4 of field 1.
func (m Msg) Path(ns ...int) (Msg, bool) {
	cur := m
	for _, n := range ns {
		s, ok := cur.Sub(n)
		if !ok {
			return nil, false
		}
		cur = s
	}
	return cur, true
}

// DurationMs reads a google.protobuf.Duration / Timestamp-shaped message
// (f1 seconds, f2 nanos) as milliseconds.
func DurationMs(m Msg) int64 { return m.Int(1)*1000 + m.Int(2)/1_000_000 }

// String renders the field structure (numbers, types, lengths and varint
// values) for debugging. It never includes payload bytes.
func (m Msg) String() string {
	s := "{"
	for i, f := range m {
		if i > 0 {
			s += " "
		}
		s += strconv.Itoa(f.Num) + ":"
		if f.Type == Bytes {
			s += "[" + strconv.Itoa(len(f.B)) + "]"
		} else {
			s += strconv.FormatUint(f.V, 10)
		}
	}
	return s + "}"
}
