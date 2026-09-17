package poller

import (
	"context"
	"testing"
	"time"
)

func TestVolumeLock_SecondHolderWaitsForRelease(t *testing.T) {
	dir := t.TempDir()

	first, err := AcquireVolumeLock(context.Background(), dir, nil)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}

	waited := make(chan string, 1)
	got := make(chan *VolumeLock, 1)

	go func() {
		l, err := AcquireVolumeLock(context.Background(), dir, func(p string) { waited <- p })
		if err != nil {
			t.Errorf("second acquire: %v", err)
		}
		got <- l
	}()

	select {
	case <-waited:
	case <-time.After(2 * time.Second):
		t.Fatal("second holder never reported waiting")
	}

	select {
	case <-got:
		t.Fatal("second holder acquired while the first still held the lock")
	case <-time.After(500 * time.Millisecond):
	}

	first.Release()

	select {
	case l := <-got:
		l.Release()
	case <-time.After(2 * time.Second):
		t.Fatal("second holder did not acquire after release")
	}
}

func TestVolumeLock_ContextCancelsTheWait(t *testing.T) {
	dir := t.TempDir()

	first, err := AcquireVolumeLock(context.Background(), dir, nil)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	defer first.Release()

	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()

	if _, err := AcquireVolumeLock(ctx, dir, nil); err == nil {
		t.Fatal("expected the wait to be cancelled by ctx")
	}
}
