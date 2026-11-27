package pb

import "testing"

func TestRoundTrip(t *testing.T) {
	inner := (&Builder{}).Uint(1, 3).Uint(2, 881103333)
	b := (&Builder{}).
		Uint(1, 150).
		Str(2, "gemini-4-neon").
		Msg(3, inner).
		Uint(4, 1<<40).
		Fixed64(5, 0x0102030405060708).
		Str(6, "a").Str(6, "b").
		Bytes()
	m, err := Parse(b)
	if err != nil {
		t.Fatal(err)
	}
	if m.Uint(1) != 150 || m.Str(2) != "gemini-4-neon" || m.Int(4) != 1<<40 {
		t.Fatalf("bad scalars: %v", m)
	}
	if f, _ := m.Last(5); f.V != 0x0102030405060708 || f.Type != Fixed64 {
		t.Fatalf("fixed64: %+v", f)
	}
	s, ok := m.Sub(3)
	if !ok || DurationMs(s) != 3881 {
		t.Fatalf("duration: %v %d", ok, DurationMs(s))
	}
	if all := m.All(6); len(all) != 2 || string(all[1].B) != "b" {
		t.Fatalf("repeated: %v", all)
	}
	if m.Str(6) != "b" {
		t.Fatal("last wins")
	}
	if _, ok := m.Sub(2); ok {
		// "gemini-4-neon" is not a valid message: 'g' = field 12 wire type 7.
		t.Fatal("string decoded as message")
	}
	if p, ok := (&Builder{}).Msg(1, (&Builder{}).Msg(4, (&Builder{}).Uint(2, 7))).bytesMsg().Path(1, 4); !ok || p.Uint(2) != 7 {
		t.Fatal("path")
	}
	if m.Uint(99) != 0 || m.Bytes(99) != nil || m.Has(99) {
		t.Fatal("missing field")
	}
}

func (w *Builder) bytesMsg() Msg { m, _ := Parse(w.Bytes()); return m }

func TestMalformed(t *testing.T) {
	cases := map[string][]byte{
		"truncated varint": {0x08, 0x80},
		"truncated bytes":  {0x12, 0x05, 'a'},
		"field zero":       {0x00, 0x01},
		"group":            {0x0b},
		"fixed32 short":    {0x0d, 1, 2},
		"overflow":         {0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01},
	}
	for name, b := range cases {
		if _, err := Parse(b); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
	if m, err := Parse(nil); err != nil || len(m) != 0 {
		t.Fatal("empty message")
	}
	if s := (Msg{{Num: 1, Type: Bytes, B: []byte("secret")}}).String(); s != "{1:[6]}" {
		t.Fatalf("String leaks payload: %s", s)
	}
}
