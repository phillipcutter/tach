package limits

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"tach/collector/internal/acct"
	"tach/collector/internal/antigravity"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
)

const lsService = "/exa.language_server_pb.LanguageServerService/"

func pollGemini(ctx context.Context, e env.Env, out *event.Emitter) {
	const src = "limits/gemini"
	var live []antigravity.Server
	for _, s := range antigravity.Servers(e.Home) {
		if s.Alive {
			live = append(live, s)
		}
	}
	if len(live) == 0 {
		out.Log("warn", src, "Antigravity is not running")
		return
	}
	var lastErr error
	for _, s := range live {
		quota, err := lsCall(ctx, s, "RetrieveUserQuotaSummary")
		if err != nil {
			lastErr = err
			continue
		}
		status, err := lsCall(ctx, s, "GetUserStatus")
		if err != nil {
			status = nil // plan and account are optional
		}
		ls, err := mapGemini(quota, status, e.Now.UnixMilli())
		if err != nil {
			lastErr = err
			continue
		}
		for _, l := range ls {
			out.Limit(l)
		}
		msg := fmt.Sprintf("answered by RetrieveUserQuotaSummary on the local language server (%d windows)", len(ls))
		if status == nil {
			msg += "; GetUserStatus failed, no plan or account"
		}
		out.Log("info", src, msg)
		return
	}
	out.Log("warn", src, "Antigravity language server did not answer: "+lastErr.Error())
}

func lsCall(ctx context.Context, s antigravity.Server, method string) ([]byte, error) {
	url := ""
	switch {
	case s.HTTPPort > 0:
		url = "http://127.0.0.1:" + strconv.Itoa(s.HTTPPort) + lsService + method
	case s.HTTPSPort > 0:
		url = "https://127.0.0.1:" + strconv.Itoa(s.HTTPSPort) + lsService + method
	default:
		return nil, errors.New("no port")
	}
	req, _ := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader([]byte("{}")))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	if s.CSRF != "" {
		req.Header.Set("X-Codeium-Csrf-Token", s.CSRF)
	}
	return do(loopbackClient, req)
}

type agQuota struct {
	Response *struct {
		Groups []struct {
			DisplayName string `json:"displayName"`
			Buckets     []struct {
				BucketID string `json:"bucketId"`
				Window   string `json:"window"`
				// Connect JSON omits zero values: an absent remainingFraction means 0 left.
				RemainingFraction *float64 `json:"remainingFraction"`
				ResetTime         string   `json:"resetTime"`
			} `json:"buckets"`
		} `json:"groups"`
	} `json:"response"`
}

type agStatus struct {
	UserStatus *struct {
		Email    string `json:"email"`
		UserTier *struct {
			Name string `json:"name"`
		} `json:"userTier"`
		PlanStatus *struct {
			PlanInfo *struct {
				PlanName string `json:"planName"`
			} `json:"planInfo"`
		} `json:"planStatus"`
	} `json:"userStatus"`
}

// AntigravityPlan returns the plan display name and hashed account from a
// GetUserStatus response.
func AntigravityPlan(status []byte) (plan, acctHash string) {
	var st agStatus
	if len(status) == 0 || json.Unmarshal(status, &st) != nil || st.UserStatus == nil {
		return "", ""
	}
	u := st.UserStatus
	if u.UserTier != nil && u.UserTier.Name != "" {
		plan = u.UserTier.Name
	} else if u.PlanStatus != nil && u.PlanStatus.PlanInfo != nil {
		plan = u.PlanStatus.PlanInfo.PlanName
	}
	return plan, acct.Email(u.Email)
}

func mapGemini(quota, status []byte, now int64) ([]event.Limit, error) {
	var q agQuota
	if err := json.Unmarshal(quota, &q); err != nil || q.Response == nil {
		return nil, errors.New("unexpected RetrieveUserQuotaSummary shape")
	}
	plan, h := AntigravityPlan(status)
	var out []event.Limit
	seen := map[string]bool{}
	for _, g := range q.Response.Groups {
		for _, b := range g.Buckets {
			group := ""
			if i := strings.IndexByte(b.BucketID, '-'); i > 0 {
				group = b.BucketID[:i]
			}
			if group != "gemini" && group != "3p" {
				if strings.Contains(strings.ToLower(g.DisplayName), "gemini") {
					group = "gemini"
				} else {
					group = "3p"
				}
			}
			glabel := "Gemini models"
			if group == "3p" {
				glabel = "Claude and GPT models"
			}
			var wid, kind, label string
			var length int64
			switch strings.ToLower(b.Window) {
			case "5h", "five_hour", "5_hour":
				wid, kind, label, length = "five_hour", "session", "5-hour", lenFiveHour
			case "weekly", "week", "7d":
				wid, kind, label, length = "weekly", "weekly", "Week", lenWeek
			default:
				continue
			}
			id := group + ":" + wid
			if seen[id] {
				continue
			}
			seen[id] = true
			rem := 0.0
			if b.RemainingFraction != nil {
				rem = *b.RemainingFraction
			}
			used := (1 - rem) * 100
			resets, _ := parseISO(b.ResetTime)
			l := window("gemini", h, plan, id, kind, label, &used, resets, length, now, "rpc")
			l.Group, l.GroupLbl = group, glabel
			l.Limited = rem <= 0
			out = append(out, l)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("no quota buckets in response")
	}
	return out, nil
}
