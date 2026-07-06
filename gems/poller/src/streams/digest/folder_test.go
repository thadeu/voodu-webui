package digest

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestComputeHash_Deterministic(t *testing.T) {
	ts := time.Unix(1700000000, 12345)
	got1 := ComputeHash("metrics", "server-1", ts)
	got2 := ComputeHash("metrics", "server-1", ts)

	if got1 != got2 {
		t.Fatalf("hash not deterministic: %q vs %q", got1, got2)
	}
	if len(got1) != 16 {
		t.Fatalf("hash length = %d, want 16", len(got1))
	}
}

func TestComputeHash_DistinctByType(t *testing.T) {
	ts := time.Unix(1700000000, 0)
	metricsHash := ComputeHash("metrics", "server-1", ts)
	stateHash := ComputeHash("state", "server-1", ts)

	if metricsHash == stateHash {
		t.Fatal("metrics + state collided on same (server, ts)")
	}
}

func TestComputeHash_DistinctByServer(t *testing.T) {
	ts := time.Unix(1700000000, 0)
	a := ComputeHash("metrics", "server-1", ts)
	b := ComputeHash("metrics", "server-2", ts)

	if a == b {
		t.Fatal("two servers collided on same (type, ts)")
	}
}

func TestWriteHashedFolder_AtomicRename(t *testing.T) {
	root := t.TempDir()
	syncHash := "deadbeef00000001"

	files := map[string]io.Reader{
		"data.ndjson": strings.NewReader("hello\nworld\n"),
	}
	meta := Meta{
		Type:     "metrics",
		ServerID: "server-1",
		TS:       time.Now().Unix(),
	}

	if err := WriteHashedFolder(root, "metrics", syncHash, files, meta); err != nil {
		t.Fatalf("write: %v", err)
	}

	folder := FolderPath(root, "metrics", syncHash)
	entries, err := os.ReadDir(folder)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}

	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Errorf(".tmp file leaked: %s", e.Name())
		}
	}

	data, err := os.ReadFile(filepath.Join(folder, "data.ndjson"))
	if err != nil {
		t.Fatalf("read data: %v", err)
	}
	if string(data) != "hello\nworld\n" {
		t.Errorf("data = %q", string(data))
	}
}

func TestWriteHashedFolder_MetaWrittenLast(t *testing.T) {
	root := t.TempDir()
	syncHash := "deadbeef00000002"

	files := map[string]io.Reader{
		"a.json": strings.NewReader(`{"a":1}`),
		"b.json": strings.NewReader(`{"b":2}`),
	}
	meta := Meta{
		Type:     "state",
		ServerID: "server-1",
		TS:       time.Now().Unix(),
	}

	if err := WriteHashedFolder(root, "state", syncHash, files, meta); err != nil {
		t.Fatalf("write: %v", err)
	}

	folder := FolderPath(root, "state", syncHash)
	metaPath := filepath.Join(folder, "meta.json")

	metaInfo, err := os.Stat(metaPath)
	if err != nil {
		t.Fatalf("meta.json missing: %v", err)
	}

	for _, name := range []string{"a.json", "b.json"} {
		info, err := os.Stat(filepath.Join(folder, name))
		if err != nil {
			t.Fatalf("payload %s missing: %v", name, err)
		}

		if metaInfo.ModTime().Before(info.ModTime()) {
			t.Errorf("meta.json mtime %v is BEFORE payload %s mtime %v",
				metaInfo.ModTime(), name, info.ModTime())
		}
	}

	raw, err := os.ReadFile(metaPath)
	if err != nil {
		t.Fatalf("read meta: %v", err)
	}

	var got Meta
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("parse meta: %v", err)
	}
	if got.Type != "state" {
		t.Errorf("meta.type = %q", got.Type)
	}
	if got.Size == 0 {
		t.Errorf("meta.size = 0 — should be auto-computed from payloads")
	}
}

func TestCountPending(t *testing.T) {
	root := t.TempDir()

	for i := 0; i < 3; i++ {
		hash := []byte("hash000000000000")
		hash[15] = byte('0' + i)
		err := WriteHashedFolder(root, "metrics", string(hash), map[string]io.Reader{
			"data.ndjson": strings.NewReader("x"),
		}, Meta{Type: "metrics", ServerID: "i", TS: time.Now().Unix()})
		if err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
	}

	n, err := CountPending(root, "metrics")
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 3 {
		t.Errorf("pending = %d, want 3", n)
	}

	n, err = CountPending(root, "state")
	if err != nil {
		t.Fatalf("count missing dir: %v", err)
	}
	if n != 0 {
		t.Errorf("empty stream pending = %d", n)
	}
}

func TestCleanupOlderThan(t *testing.T) {
	root := t.TempDir()

	oldHash := "old0000000000001"
	newHash := "new0000000000001"

	err := WriteHashedFolder(root, "metrics", oldHash, map[string]io.Reader{
		"data.ndjson": strings.NewReader("old"),
	}, Meta{Type: "metrics", ServerID: "i", TS: time.Now().Unix()})
	if err != nil {
		t.Fatalf("write old: %v", err)
	}

	err = WriteHashedFolder(root, "metrics", newHash, map[string]io.Reader{
		"data.ndjson": strings.NewReader("new"),
	}, Meta{Type: "metrics", ServerID: "i", TS: time.Now().Unix()})
	if err != nil {
		t.Fatalf("write new: %v", err)
	}

	oldMeta := filepath.Join(FolderPath(root, "metrics", oldHash), "meta.json")
	past := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(oldMeta, past, past); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	cutoff := time.Now().Add(-time.Hour)
	if err := CleanupOlderThan(root, "metrics", cutoff); err != nil {
		t.Fatalf("cleanup: %v", err)
	}

	if _, err := os.Stat(FolderPath(root, "metrics", oldHash)); !os.IsNotExist(err) {
		t.Errorf("old folder should be gone: err=%v", err)
	}
	if _, err := os.Stat(FolderPath(root, "metrics", newHash)); err != nil {
		t.Errorf("new folder should survive: err=%v", err)
	}
}
