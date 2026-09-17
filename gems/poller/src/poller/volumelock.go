package poller

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// VolumeLock is the one-writer guarantee for the storage volume.
//
// The console deploys blue/green: for a window the old pod and the new pod
// are both up, and each Puma has spawned its own poller. Two pollers on the
// same volume append to the same NDJSON log files and drop the same digest
// folders — interleaved half-lines the parser then discards, duplicated or
// skipped log ranges, orphaned digests. The deploy doc forbids it, but the
// rollout does it anyway.
//
// An exclusive flock(2) on a file in the volume turns the overlap into a
// hand-off: the new poller blocks in Acquire until the old one exits (a
// TERM from its Puma, or a KILL — the kernel releases a flock with the
// process either way), then takes over with no gap and no shared writes.
type VolumeLock struct {
	f *os.File
}

// LockFileName is the lock file, at the root of the storage dir.
const LockFileName = ".poller.lock"

// AcquireVolumeLock takes the exclusive lock, waiting for a holder to
// release it. `waiting` is called once if the lock is held at first try,
// so the operator can see "waiting for the running poller" in the log
// instead of a silent stall. Returns when locked or when ctx ends.
func AcquireVolumeLock(ctx context.Context, storageDir string, waiting func(path string)) (*VolumeLock, error) {
	path := filepath.Join(storageDir, LockFileName)

	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644) // #nosec G304 -- our own storage dir

	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}

	// Fast path: free right now.
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		return &VolumeLock{f: f}, nil
	}

	if waiting != nil {
		waiting(path)
	}

	// Slow path: poll with LOCK_NB so ctx can cancel the wait (a blocking
	// LOCK_EX cannot be interrupted from Go).
	t := time.NewTicker(250 * time.Millisecond)
	defer t.Stop()

	for {
		select {
		case <-ctx.Done():
			_ = f.Close()

			return nil, ctx.Err()
		case <-t.C:
			if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
				return &VolumeLock{f: f}, nil
			}
		}
	}
}

// Release drops the lock. Safe to call more than once.
func (l *VolumeLock) Release() {
	if l == nil || l.f == nil {
		return
	}

	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	_ = l.f.Close()
	l.f = nil
}
