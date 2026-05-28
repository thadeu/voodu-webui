// Package poller is the heart of the log poller: per-island
// goroutines, watermark sidecars, NDJSON writers, and the dedup ring.
package poller

// DedupRing is a fixed-capacity sliding window of recently-seen hashes.
//
// Used by the poller to suppress lines that the controller re-emits on
// every tick (this happens whenever `since=<watermark>` rounds to the
// same second as a previously-persisted line). 5000 entries / pod is
// ~ ten minutes of high-volume traffic; way more than the
// 15s poll interval needs.
//
// Implementation: ring buffer of uint64 hashes + a map for O(1)
// lookup. Inserting an entry evicts the oldest slot and removes its
// hash from the map, so memory is bounded.
//
// Not safe for concurrent use — each pod has its own goroutine, and
// each goroutine owns its DedupRing.
type DedupRing struct {
	buf    []uint64
	index  map[uint64]int // hash -> slot in buf
	cursor int            // next slot to write
	size   int            // number of populated slots (≤ cap)
}

// NewDedupRing returns a ring with the given capacity. capacity must be
// > 0; we panic otherwise (programmer error, not runtime).
func NewDedupRing(capacity int) *DedupRing {
	if capacity <= 0 {
		panic("dedup: capacity must be > 0")
	}

	return &DedupRing{
		buf:   make([]uint64, capacity),
		index: make(map[uint64]int, capacity),
	}
}

// Seen reports whether `hash` is in the window.
func (r *DedupRing) Seen(hash uint64) bool {
	_, ok := r.index[hash]

	return ok
}

// Record inserts `hash` into the window, evicting the oldest slot if
// the ring is full. Idempotent — calling Record twice with the same
// hash leaves the window unchanged after the first call (the second
// would re-insert at the cursor, which is wrong, so we no-op).
func (r *DedupRing) Record(hash uint64) {
	if _, ok := r.index[hash]; ok {
		return
	}

	if r.size == len(r.buf) {
		// Evict the slot we are about to overwrite.
		delete(r.index, r.buf[r.cursor])
	} else {
		r.size++
	}

	r.buf[r.cursor] = hash
	r.index[hash] = r.cursor
	r.cursor = (r.cursor + 1) % len(r.buf)
}

// Len returns the current number of populated slots.
func (r *DedupRing) Len() int { return r.size }
