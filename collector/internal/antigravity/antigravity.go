// Package antigravity reads usage written by Google Antigravity: one SQLite file
// per conversation with protobuf blobs, decoded by field number. See
// docs/collector-protocol.md and design/data-sources.md section 3.7.
package antigravity

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"tach/collector/internal/cursor"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
)

const tool = "antigravity"

// Scan emits one req per generation not emitted before, and advances cur.
//
// Cursor: one cursor.File per conversation DB, with Off = the next gen_metadata
// idx to read. A DB whose inode, size and mtime are unchanged costs one stat.
func Scan(ctx context.Context, e env.Env, cur *cursor.State, out *event.Emitter) error {
	dir := ConversationsDir(e.Home)
	dbs, err := filepath.Glob(filepath.Join(dir, "*.db"))
	if err != nil || len(dbs) == 0 {
		return nil // not installed, or nothing yet
	}
	var todo []job
	for _, p := range dbs {
		st, err := os.Stat(p)
		if err != nil || !st.Mode().IsRegular() {
			continue
		}
		f := cursor.File{Ino: inode(st), Size: st.Size(), Mtime: st.ModTime().UnixMilli()}
		prev, seen := cur.Get(p)
		if seen && prev.Ino == f.Ino && prev.Size == f.Size && prev.Mtime == f.Mtime {
			continue
		}
		j := job{path: p, file: f, first: !seen}
		if seen && prev.Ino == f.Ino && f.Size >= prev.Size {
			j.from = prev.Off
		}
		if !seen && st.ModTime().Before(e.Since) {
			continue // first scan: untouched since the backfill cap
		}
		todo = append(todo, j)
	}
	if len(todo) == 0 {
		return nil
	}
	sums, err := loadSummaries(ctx, e.Home)
	if err != nil && e.Verbose {
		fmt.Fprintln(os.Stderr, "antigravity: conversation_summaries.db:", err)
	}
	var (
		wg    sync.WaitGroup
		mu    sync.Mutex
		stats scanStats
		sem   = make(chan struct{}, 4)
	)
	for _, j := range todo {
		wg.Add(1)
		go func(j job) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			st, next, err := scanDB(ctx, e, j, sums, out)
			mu.Lock()
			stats.add(st)
			mu.Unlock()
			if err != nil {
				out.Log("warn", tool, filepath.Base(j.path)+": "+err.Error())
				return
			}
			j.file.Off = next
			cur.Set(j.path, j.file)
		}(j)
	}
	wg.Wait()
	if stats.bad > 0 {
		out.Log("warn", tool, fmt.Sprintf("skipped %d of %d generations that failed sanity checks (layout change?): %s",
			stats.bad, stats.total, stats.why()))
	}
	if e.Verbose {
		fmt.Fprintf(os.Stderr, "antigravity: %d dbs, %d generations, %d emitted, %d without usage, %d bad\n",
			len(todo), stats.total, stats.emitted, stats.noUsage, stats.bad)
	}
	return nil
}

type job struct {
	path  string
	file  cursor.File
	from  int64
	first bool
}

type scanStats struct {
	total, emitted, noUsage, bad int
	reasons                      map[string]int
}

func (s *scanStats) add(o scanStats) {
	s.total += o.total
	s.emitted += o.emitted
	s.noUsage += o.noUsage
	s.bad += o.bad
	for k, v := range o.reasons {
		if s.reasons == nil {
			s.reasons = map[string]int{}
		}
		s.reasons[k] += v
	}
}

func (s scanStats) why() string {
	var p []string
	for k, v := range s.reasons {
		p = append(p, k+" x"+strconv.Itoa(v))
	}
	return strings.Join(p, ", ")
}

func scanDB(ctx context.Context, e env.Env, j job, sums map[string]summary, out *event.Emitter) (scanStats, int64, error) {
	var st scanStats
	cascade := strings.TrimSuffix(filepath.Base(j.path), ".db")
	db, err := OpenRO(j.path)
	if err != nil {
		return st, j.from, err
	}
	defer db.Close()

	var maxIdx sql.NullInt64
	if err := db.QueryRowContext(ctx, `SELECT MAX(idx) FROM gen_metadata`).Scan(&maxIdx); err != nil {
		return st, j.from, err
	}
	if !maxIdx.Valid || maxIdx.Int64 < j.from {
		return st, j.from, nil
	}
	times, err := genTimes(ctx, db)
	if err != nil {
		return st, j.from, err
	}
	rows, err := db.QueryContext(ctx, `SELECT idx, data FROM gen_metadata WHERE idx >= ? ORDER BY idx`, j.from)
	if err != nil {
		return st, j.from, err
	}
	defer rows.Close()

	sum := sums[cascade]
	next := j.from
	pendingTail := int64(-1) // first idx of a trailing run of rows without usage yet
	mtime := j.file.Mtime
	for rows.Next() {
		var idx int64
		var data []byte
		if rows.Scan(&idx, &data) != nil {
			continue
		}
		st.total++
		g, err := decodeGen(data)
		if err == errNoUsage || err == errNoMeta {
			// Possibly still streaming: do not move the cursor past a trailing run of these.
			st.noUsage++
			if pendingTail < 0 {
				pendingTail = idx
			}
			continue
		}
		pendingTail = -1
		next = idx + 1
		if err != nil {
			st.bad++
			if st.reasons == nil {
				st.reasons = map[string]int{}
			}
			st.reasons[err.Error()]++
			continue
		}
		t := times[idx]
		ts := t.Completed
		if ts == 0 && t.Created > 0 {
			ts = t.Created + max(g.TTFT, 0) + max(g.Stream, 0)
		}
		if ts == 0 {
			ts = mtime
		}
		if j.first && ts < e.Since.UnixMilli() {
			continue
		}
		out.Req(toReq(cascade, idx, ts, g, sum))
		st.emitted++
	}
	if err := rows.Err(); err != nil {
		return st, j.from, err
	}
	// A trailing row without usage that is old is not going to fill in: skip it for good.
	if pendingTail >= 0 && time.Since(time.UnixMilli(mtime)) > 24*time.Hour {
		next = maxIdx.Int64 + 1
	}
	return st, next, nil
}

func toReq(cascade string, idx, ts int64, g gen, sum summary) event.Req {
	r := event.Req{
		Tool:     tool,
		Key:      g.Labels["request_id"],
		TS:       ts,
		Model:    g.Model,
		Provider: providerFor(g.Model),
		Pool:     poolFor(g.Model, g.Labels),
		Session:  cascade,
		Cwd:      sum.Workspace,
		Sub:      sum.Parent != "" || sum.Nesting > 0 || g.Labels["parent_cascade_id"] != "" || g.Labels["subagent_type"] != "",
		In:       g.In,
		CR:       g.CR,
		CW5:      g.CW,
		Out:      g.Out,
		Think:    g.Think,
		TQ:       "none",
		Effort:   effortFromDisplay(g.Display),
		Name:     nameFromDisplay(g.Display),
	}
	if r.Key == "" {
		r.Key = cascade + ":" + strconv.FormatInt(idx, 10)
	}
	if r.Model == "" {
		r.Model = "unknown"
	}
	if g.TTFT >= 0 && g.Stream >= 0 {
		ttft, dur := g.TTFT, g.TTFT+g.Stream // dur covers the whole request: TTFT + streaming
		r.TTFT, r.Dur, r.TQ = &ttft, &dur, "exact"
	}
	return r
}

// genTimes maps gen_metadata idx to the timing of the step that produced it.
func genTimes(ctx context.Context, db *sql.DB) (map[int64]stepTimes, error) {
	rows, err := db.QueryContext(ctx, `SELECT step_type, metadata FROM steps ORDER BY idx`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	m := map[int64]stepTimes{}
	resp := map[int64]bool{}
	for rows.Next() {
		var typ int64
		var md []byte
		if rows.Scan(&typ, &md) != nil || len(md) == 0 {
			continue
		}
		t, ok := decodeStepMeta(typ, md)
		if !ok || t.GenIdx < 0 {
			continue
		}
		isResp := typ == stepModelResponse
		if _, have := m[t.GenIdx]; have && (resp[t.GenIdx] || !isResp) {
			continue // keep the model-response step, else the first step that references it
		}
		if !isResp && t.Completed == 0 {
			t.Completed = t.Created // a follow-on step was created after the generation finished
		}
		m[t.GenIdx] = t
		resp[t.GenIdx] = isResp
	}
	return m, rows.Err()
}

// Sessions emits one session per conversation that is busy or was modified in
// the last 30 minutes, from conversation_summaries.db.
func Sessions(ctx context.Context, e env.Env, out *event.Emitter) error {
	if _, err := os.Stat(Root(e.Home)); err != nil {
		return nil
	}
	sums, err := loadSummaries(ctx, e.Home)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("conversation_summaries.db: %w", err)
	}
	running := false
	for _, s := range Servers(e.Home) {
		running = running || s.Alive
	}
	now := e.Now.UnixMilli()
	for _, s := range sums {
		if s.Killed || s.Updated == 0 {
			continue
		}
		age := now - s.Updated
		busy := s.busy() && running
		if !(age <= 30*60*1000 || (busy && age <= 6*3600*1000)) {
			continue
		}
		ev := event.Session{Tool: tool, ID: s.ID, Cwd: s.Workspace, Status: "idle", Updated: s.Updated}
		if busy {
			ev.Status = "busy"
		}
		lastGen(ctx, filepath.Join(ConversationsDir(e.Home), s.ID+".db"), &ev)
		out.Session(ev)
	}
	return nil
}

// lastGen fills model, context fill and start time from the conversation DB.
func lastGen(ctx context.Context, path string, ev *event.Session) {
	db, err := OpenRO(path)
	if err != nil {
		return
	}
	defer db.Close()
	if rows, err := db.QueryContext(ctx, `SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 5`); err == nil {
		for rows.Next() {
			var data []byte
			if rows.Scan(&data) != nil {
				continue
			}
			g, err := decodeGen(data)
			if err != nil || g.Model == "" {
				continue
			}
			ev.Model = g.Model
			if g.CtxMax > 0 {
				ev.Ctx = float64(int(float64(g.CtxUsed)/float64(g.CtxMax)*1000+0.5)) / 10
				ev.Tokens = g.CtxUsed
			}
			break
		}
		rows.Close()
	}
	var typ int64
	var md []byte
	if db.QueryRowContext(ctx, `SELECT step_type, metadata FROM steps ORDER BY idx LIMIT 1`).Scan(&typ, &md) == nil {
		if t, ok := decodeStepMeta(typ, md); ok {
			ev.Started = t.Created
		}
	}
}

func parseTime(s string) int64 {
	s = strings.TrimSpace(s)
	for _, l := range []string{"2006-01-02 15:04:05.999999999-07:00", "2006-01-02 15:04:05-07:00", time.RFC3339Nano, "2006-01-02 15:04:05"} {
		if t, err := time.Parse(l, s); err == nil {
			if t.Year() < 2000 {
				return 0
			}
			return t.UnixMilli()
		}
	}
	return 0
}
