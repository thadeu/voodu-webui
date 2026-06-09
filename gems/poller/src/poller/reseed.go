package poller

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/cespare/xxhash/v2"
)

// lineHash is the dedup identity of one log line: (pod, ts, msg).
//
// It MUST be computed identically at write time (tick) and at seed time
// (seedRing), so a line the controller re-emits after a poller restart
// hashes to the same value as the copy already on disk. `ts` is
// normalised to UTC so RFC3339Nano formatting is stable regardless of
// the source offset token ("Z" vs "+00:00") — both the freshly parsed
// timestamp and the one round-tripped through the NDJSON file land on
// the same string.
func lineHash(pod string, ts time.Time, msg string) uint64 {
	return xxhash.Sum64String(pod + "|" + ts.UTC().Format(time.RFC3339Nano) + "|" + msg)
}

// seedReadMaxBytes bounds how much of each day file we read from the
// tail when warming a ring. The re-fetch overlap after a restart is at
// most `tail=500` lines per pod (see VooduClient.FetchLogs), so a few
// MB of the most recent lines is plenty; we never load a whole (up to
// PerFileCapBytes = 250MB) day file.
const seedReadMaxBytes = 8 * 1024 * 1024

// seedRing warms a freshly-created ring with the hashes of the pod's
// most recently persisted lines, so a poller restart does not re-write
// lines the previous process already persisted.
//
// Why this is needed: `since` is the OLDEST watermark across the
// island's pods (oldestWatermark), so the first tick after a restart
// re-fetches lines that are already on disk. The in-memory ring is
// empty on a fresh process and would re-admit — and the writer would
// re-append — every one of them, producing the duplicate "blocks" we
// saw in the warehouse (one block per restart, per pod). Seeding from
// disk makes the (pod, ts, msg) dedup durable across restarts.
//
// Walks the pod's day files newest-first, accumulating hashes until the
// ring's capacity is filled. We can't assume the re-fetch overlap stays
// within one day: `since=oldestWatermark` can lag up to RETENTION_DAYS
// (a stale/stopped pod drags it back), and `tail=500` on a low-volume
// pod re-delivers lines spanning several day files. Filling from the
// newest files covers exactly the lines most likely to be re-fetched.
//
// Best-effort: any read/parse error is skipped silently — a missing or
// partially-seeded ring only costs a few duplicate lines on the first
// tick, never correctness of the live stream.
func (p *IslandPoller) seedRing(pod string, ring *DedupRing) {
	dir := filepath.Join(p.Root, p.Island.ID, safePodName(pod))

	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}

	files := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".ndjson") {
			continue
		}

		files = append(files, e.Name())
	}

	// YYYY-MM-DD.ndjson sorts lexically == chronologically; reverse to
	// get newest first.
	sort.Sort(sort.Reverse(sort.StringSlice(files)))

	limit := ring.Cap()
	hashes := make([]uint64, 0, limit) // built oldest-first

	for _, name := range files {
		if len(hashes) >= limit {
			break
		}

		hs, err := tailHashes(filepath.Join(dir, name), limit)
		if err != nil {
			continue
		}

		// Older file's lines precede the already-collected newer ones.
		hashes = append(hs, hashes...)
	}

	// Keep only the newest `limit` hashes, recorded oldest-first so any
	// eviction drops the oldest.
	if len(hashes) > limit {
		hashes = hashes[len(hashes)-limit:]
	}

	for _, h := range hashes {
		ring.Record(h)
	}
}

// tailHashes reads up to `max` of the most recent NDJSON records from
// `path` and returns their dedup hashes in chronological (oldest-first)
// order. It reads at most seedReadMaxBytes from the END of the file, so
// a large day file is never loaded whole.
func tailHashes(path string, max int) ([]uint64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return nil, err
	}

	start := int64(0)
	if info.Size() > seedReadMaxBytes {
		start = info.Size() - seedReadMaxBytes
	}

	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return nil, err
	}

	data, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}

	// Drop the first (partial) line when we seeked past the start.
	if start > 0 {
		if nl := bytes.IndexByte(data, '\n'); nl >= 0 {
			data = data[nl+1:]
		}
	}

	hashes := make([]uint64, 0, max)
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for sc.Scan() {
		var rec Record
		if err := json.Unmarshal(sc.Bytes(), &rec); err != nil {
			continue
		}

		hashes = append(hashes, lineHash(rec.Pod, rec.TS, rec.Msg))
	}

	// Keep only the newest `max` from this file.
	if len(hashes) > max {
		hashes = hashes[len(hashes)-max:]
	}

	return hashes, nil
}
