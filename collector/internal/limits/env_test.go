package limits

import (
	"time"

	"tach/collector/internal/env"
)

func testEnv() env.Env {
	return env.Env{Home: "/nonexistent", Now: time.UnixMilli(now), Since: time.UnixMilli(now).Add(-720 * time.Hour)}
}
