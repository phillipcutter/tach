package pb

// Builder encodes messages. It exists for tests that need synthetic blobs.
type Builder struct{ b []byte }

func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func (w *Builder) key(n, t int) { w.b = appendVarint(w.b, uint64(n)<<3|uint64(t)) }

// Uint appends a varint field.
func (w *Builder) Uint(n int, v uint64) *Builder {
	w.key(n, Varint)
	w.b = appendVarint(w.b, v)
	return w
}

// Raw appends a length-delimited field.
func (w *Builder) Raw(n int, p []byte) *Builder {
	w.key(n, Bytes)
	w.b = appendVarint(w.b, uint64(len(p)))
	w.b = append(w.b, p...)
	return w
}

// Str appends a string field.
func (w *Builder) Str(n int, s string) *Builder { return w.Raw(n, []byte(s)) }

// Msg appends a nested message field.
func (w *Builder) Msg(n int, m *Builder) *Builder { return w.Raw(n, m.Bytes()) }

// Fixed64 appends a fixed64 field.
func (w *Builder) Fixed64(n int, v uint64) *Builder {
	w.key(n, Fixed64)
	for i := 0; i < 8; i++ {
		w.b = append(w.b, byte(v>>(8*i)))
	}
	return w
}

// Bytes returns the encoded message.
func (w *Builder) Bytes() []byte { return w.b }
