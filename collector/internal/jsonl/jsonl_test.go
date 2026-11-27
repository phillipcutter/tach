package jsonl

import (
	"bytes"
	"strings"
	"testing"
)

func TestLines(t *testing.T) {
	long := `{"type":"x","pad":"` + strings.Repeat("a", 3<<20) + `"}`
	skipped := `{"type":"user","pad":"` + strings.Repeat("b", 3<<20) + `"}`
	in := "a\r\n" + long + "\n" + skipped + "\nb\npartial"
	var got []string
	var offs []int64
	var st Stats
	end, err := Lines(strings.NewReader(in), 100, &st, [][]byte{[]byte(`"type":"x"`)}, func(l []byte, at int64) bool {
		got = append(got, string(l[:min(len(l), 10)]))
		offs = append(offs, at)
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
	if want := int64(100 + len(in) - len("partial")); end != want {
		t.Errorf("end %d want %d", end, want)
	}
	if len(got) != 3 || got[0] != "a" || !strings.HasPrefix(got[1], `{"type":"x`) || got[2] != "b" {
		t.Errorf("lines %q", got)
	}
	if offs[2] != int64(100+len(in)-len("b\npartial")) {
		t.Errorf("offset of b = %d", offs[2])
	}
	if st.Lines != 4 {
		t.Errorf("stats %+v", st)
	}
}

func TestThin(t *testing.T) {
	type r struct {
		w  string
		ts int64
	}
	in := []r{{"a", 0}, {"a", 60_000}, {"a", 400_000}, {"a", 420_000}, {"b", 1}}
	out := Thin(in, func(x r) string { return x.w }, func(x r) int64 { return x.ts })
	var b bytes.Buffer
	for _, x := range out {
		b.WriteString(x.w)
	}
	// newest a (420000) kept, 400000 dropped, 60000 kept (360 s older), 0 dropped.
	if len(out) != 3 || out[1].w != "a" || out[1].ts != 60_000 {
		t.Errorf("thin = %+v", out)
	}
	if out[len(out)-1].ts != 420_000 {
		t.Errorf("newest not kept: %+v", out)
	}
}
