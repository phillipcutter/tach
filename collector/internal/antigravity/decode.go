package antigravity

import (
	"errors"
	"strings"

	"tach/collector/internal/pb"
)

// Field numbers, from the descriptors embedded in the language_server binary and
// matched against real rows (Antigravity 2.35.1). See design/data-sources.md 3.7.
const (
	// gen_metadata.data
	genChatMeta = 1 // ChatModelMetadata
	// ChatModelMetadata
	cmmUsage     = 4  // ModelUsageStats
	cmmContext   = 9  // f10 = {f1 tokens in context, f4 context window}
	cmmTTFT      = 11 // Duration
	cmmStreaming = 12 // Duration
	cmmModel     = 19 // response model id
	cmmLabels    = 20 // repeated {f1 key, f2 value}
	cmmDisplay   = 21 // display name, e.g. "Gemini 4 Neon (Medium)"
	cmmCtxInner  = 10
	ctxUsed      = 1
	ctxWindow    = 4
	// ModelUsageStats
	usModelEnum = 1
	usInput     = 2 // uncached input
	usOutput    = 3 // thinking + response
	usCacheW    = 4
	usCacheR    = 5
	usThinking  = 9
	usResponse  = 10
	// steps.metadata
	smCreated   = 1  // Timestamp
	smFirstTok  = 6  // Timestamp
	smCompleted = 7  // Timestamp
	smDone      = 8  // Timestamp
	smGenRef    = 20 // {f1 trajectory id, f2 step idx, f3 gen_metadata idx, f4 cascade id}
	smGenIdx    = 3
	smFinished  = 32 // Timestamp

	stepModelResponse = 15
)

var (
	errNoMeta   = errors.New("no ChatModelMetadata")
	errNoUsage  = errors.New("no usage")
	errSanity   = errors.New("output != thinking + response")
	errImplaus  = errors.New("implausible value")
	maxTokens   = uint64(50_000_000)
	maxDuration = int64(24 * 3600 * 1000)
)

// gen is what the collector keeps from one gen_metadata row. It deliberately has
// no room for prompt or response text.
type gen struct {
	Model    string
	Display  string
	In, Out  int64
	CR, CW   int64
	Think    int64
	TTFT     int64 // ms; -1 when absent
	Stream   int64 // ms; -1 when absent
	CtxUsed  int64
	CtxMax   int64
	Labels   map[string]string
	HasUsage bool
}

// labelKeys are the only label values kept; everything else is dropped unread.
var labelKeys = map[string]bool{
	"request_id": true, "cascade_id": true, "root_cascade_id": true, "trajectory_id": true,
	"used_claude": true, "used_non_gemini_model": true, "parent_cascade_id": true, "subagent_type": true,
}

func decodeGen(data []byte) (gen, error) {
	g := gen{TTFT: -1, Stream: -1}
	top, err := pb.Parse(data)
	if err != nil {
		return g, err
	}
	cmm, ok := top.Sub(genChatMeta)
	if !ok {
		return g, errNoMeta
	}
	g.Model = cmm.Str(cmmModel)
	g.Display = cmm.Str(cmmDisplay)
	for _, f := range cmm.All(cmmLabels) {
		if f.Type != pb.Bytes {
			continue
		}
		kv, err := pb.Parse(f.B)
		if err != nil {
			continue
		}
		if k := kv.Str(1); labelKeys[k] {
			if g.Labels == nil {
				g.Labels = map[string]string{}
			}
			g.Labels[k] = kv.Str(2)
		}
	}
	if d, ok := cmm.Sub(cmmTTFT); ok {
		g.TTFT = pb.DurationMs(d)
	}
	if d, ok := cmm.Sub(cmmStreaming); ok {
		g.Stream = pb.DurationMs(d)
	}
	if c, ok := cmm.Path(cmmContext, cmmCtxInner); ok {
		g.CtxUsed, g.CtxMax = c.Int(ctxUsed), c.Int(ctxWindow)
	}
	u, ok := cmm.Sub(cmmUsage)
	if !ok || !(u.Has(usInput) || u.Has(usOutput) || u.Has(usCacheR)) {
		return g, errNoUsage
	}
	g.HasUsage = true
	for _, n := range []int{usInput, usOutput, usCacheW, usCacheR, usThinking, usResponse} {
		if u.Uint(n) > maxTokens {
			return g, errImplaus
		}
	}
	g.In, g.Out = u.Int(usInput), u.Int(usOutput)
	g.CW, g.CR = u.Int(usCacheW), u.Int(usCacheR)
	g.Think = u.Int(usThinking)
	if th, rs := g.Think, u.Int(usResponse); th+rs > 0 && th+rs != g.Out {
		return g, errSanity
	}
	if g.TTFT > maxDuration || g.Stream > maxDuration || g.TTFT < -1 || g.Stream < -1 {
		return g, errImplaus
	}
	return g, nil
}

// stepTimes is what the collector keeps from steps.metadata.
type stepTimes struct {
	GenIdx    int64 // -1 when the step does not reference a generation
	Created   int64 // unix ms, 0 when absent
	Completed int64
}

func decodeStepMeta(stepType int64, data []byte) (stepTimes, bool) {
	st := stepTimes{GenIdx: -1}
	m, err := pb.Parse(data)
	if err != nil {
		return st, false
	}
	ts := func(n int) int64 {
		if s, ok := m.Sub(n); ok {
			return pb.DurationMs(s)
		}
		return 0
	}
	st.Created = ts(smCreated)
	for _, n := range []int{smCompleted, smDone, smFinished} {
		if v := ts(n); v > 0 {
			st.Completed = v
			break
		}
	}
	if ref, ok := m.Sub(smGenRef); ok {
		// proto3 omits a zero index; only a model-response step's own reference
		// can be trusted to mean generation 0 in that case.
		if ref.Has(smGenIdx) || stepType == stepModelResponse {
			st.GenIdx = ref.Int(smGenIdx)
		}
	}
	return st, true
}

// effortFromDisplay pulls "medium" out of "Gemini 4 Neon (Medium)".
func effortFromDisplay(d string) string {
	i := strings.LastIndexByte(d, '(')
	j := strings.LastIndexByte(d, ')')
	if i < 0 || j <= i+1 || j-i > 20 {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(d[i+1 : j]))
}

// poolFor names the Antigravity subscription pool a generation draws on.
func poolFor(model string, labels map[string]string) string {
	if labels["used_claude"] == "true" || labels["used_non_gemini_model"] == "true" {
		return "gemini_3p"
	}
	m := strings.ToLower(model)
	if m == "" || strings.HasPrefix(m, "gemini") {
		return "gemini"
	}
	return "gemini_3p"
}

func providerFor(model string) string {
	m := strings.ToLower(model)
	switch {
	case strings.HasPrefix(m, "gemini"):
		return "google"
	case strings.HasPrefix(m, "claude"):
		return "anthropic"
	case strings.HasPrefix(m, "gpt"), strings.HasPrefix(m, "o1"), strings.HasPrefix(m, "o3"), strings.HasPrefix(m, "o4"):
		return "openai"
	}
	return "other"
}

// nameFromDisplay drops the effort suffix: "Gemini 4 Neon (Medium)" becomes "Gemini 4 Neon".
func nameFromDisplay(d string) string {
	d = strings.TrimSpace(d)
	if i := strings.LastIndex(d, " ("); i > 0 && strings.HasSuffix(d, ")") {
		d = d[:i]
	}
	return d
}
