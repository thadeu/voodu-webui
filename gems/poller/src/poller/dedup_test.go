package poller

import "testing"

func TestDedupRing_RecordSeen(t *testing.T) {
	r := NewDedupRing(3)

	if r.Seen(1) {
		t.Fatal("empty ring claims to have seen 1")
	}

	r.Record(1)
	if !r.Seen(1) {
		t.Fatal("after Record(1), ring should report Seen(1)")
	}
	if r.Len() != 1 {
		t.Fatalf("len=%d, want 1", r.Len())
	}

	// Idempotent.
	r.Record(1)
	if r.Len() != 1 {
		t.Fatalf("re-Record(1): len=%d, want 1", r.Len())
	}
}

func TestDedupRing_Eviction(t *testing.T) {
	r := NewDedupRing(3)

	r.Record(1)
	r.Record(2)
	r.Record(3)

	// Should be full; all three present.
	for _, h := range []uint64{1, 2, 3} {
		if !r.Seen(h) {
			t.Fatalf("expected Seen(%d)", h)
		}
	}

	// Insert a 4th: 1 should be evicted (oldest).
	r.Record(4)

	if r.Seen(1) {
		t.Fatal("after Record(4) on cap=3, 1 should be evicted")
	}
	if !r.Seen(2) || !r.Seen(3) || !r.Seen(4) {
		t.Fatal("after Record(4), 2/3/4 should all be Seen")
	}
	if r.Len() != 3 {
		t.Fatalf("len=%d, want 3", r.Len())
	}
}

func TestDedupRing_PanicsOnZeroCap(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic on zero capacity")
		}
	}()

	_ = NewDedupRing(0)
}
