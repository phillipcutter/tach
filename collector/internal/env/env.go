// Package env carries the run settings shared by every source.
package env

import "time"

type Env struct {
	Home    string    // home directory to read tool data from
	Since   time.Time // ignore events older than this (first-run backfill cap)
	Now     time.Time
	Verbose bool
}
