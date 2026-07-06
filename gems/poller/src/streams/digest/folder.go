// Package digest is the shared on-disk layout for the metrics + state
// streams. Each "digest" is one folder under
// storage/poller/<streamType>/<syncHash>/ containing the raw response
// payload(s) plus a meta.json marker written LAST.
//
// The folder is considered "complete" only when meta.json exists; Rails
// readers MUST check for meta.json before parsing the other files.
//
// The shared cap (MaxPendingFolders) protects against disk fill when
// the Rails notify endpoint is down — once a stream type accumulates
// too many unprocessed folders, the fetcher backs off and waits for the
// cleanup goroutine to catch up.
package digest

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/cespare/xxhash/v2"
)

// MaxPendingFolders — soft cap per stream type. When the per-type
// folder count exceeds this, the fetcher skips the tick and bumps
// an error counter so the operator sees the backlog.
const MaxPendingFolders = 200

// PendingTTL is how long a folder lingers in storage before the cleanup
// loop considers it garbage. Rails should normally process within
// seconds; one hour leaves plenty of slack for transient outages.
const PendingTTL = time.Hour

// Meta is the marker file written last in each digest folder. The
// timestamp drives the cleanup GC; size is the on-disk total (sum of
// payload files) so Rails can sanity-check before reading.
//
// `ServerID` is the Rails-side Server primary key (passed as string so
// the JSON envelope is uniform across Go services that don't know /
// care that the stable identifier is integer-backed). Server is the
// platform-internal name for "operator-managed scope" — `server_id`
// in this contract is the same value that ends up on the `poller_digests`
// table on the Rails side.
type Meta struct {
	Type     string `json:"type"`
	ServerID string `json:"server_id"`
	TS       int64  `json:"ts"`
	Size     int    `json:"size"`
	Since    string `json:"since,omitempty"`
}

// ComputeHash returns a 16-hex xxhash64 over the stream type, server id
// and tick timestamp (nanoseconds). The collision space is far past
// what one poller will ever produce within the retention window.
func ComputeHash(streamType, serverID string, ts time.Time) string {
	key := fmt.Sprintf("%s|%s|%d", streamType, serverID, ts.UnixNano())

	return fmt.Sprintf("%016x", xxhash.Sum64String(key))
}

// FolderPath returns the absolute path the writer would target. Does
// not create the directory.
func FolderPath(root, streamType, syncHash string) string {
	return filepath.Join(root, "poller", streamType, syncHash)
}

// StreamRoot returns storage/poller/<streamType>/. Used by the pending
// folder count and by the cleanup walker.
func StreamRoot(root, streamType string) string {
	return filepath.Join(root, "poller", streamType)
}

// CountPending returns the number of subdirectories under
// storage/poller/<streamType>/. Used as a soft cap check before the
// fetcher writes a new folder.
func CountPending(root, streamType string) (int, error) {
	entries, err := os.ReadDir(StreamRoot(root, streamType))
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}

		return 0, err
	}

	n := 0
	for _, e := range entries {
		if e.IsDir() {
			n++
		}
	}

	return n, nil
}

// WriteHashedFolder materialises a complete digest folder. Each entry
// in `files` is written as `<name>.tmp` then atomically renamed to
// `<name>`. meta.json is written LAST (same tmp+rename dance) so a
// crashed write never leaves a half-populated folder that looks
// complete to the Rails reader.
//
// The folder itself is created via os.MkdirAll; if it already exists
// (hash collision within the same nanosecond — vanishingly unlikely),
// the existing files are overwritten via the rename.
func WriteHashedFolder(root, streamType, syncHash string, files map[string]io.Reader, meta Meta) error {
	folder := FolderPath(root, streamType, syncHash)
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return fmt.Errorf("mkdir digest folder: %w", err)
	}

	totalSize := 0
	for name, r := range files {
		size, err := writeAtomic(folder, name, r)
		if err != nil {
			return fmt.Errorf("write %s: %w", name, err)
		}

		totalSize += size
	}

	if meta.Size == 0 {
		meta.Size = totalSize
	}

	metaBytes, err := json.Marshal(meta)
	if err != nil {
		return fmt.Errorf("encode meta: %w", err)
	}

	if _, err := writeAtomic(folder, "meta.json", bytesReader(metaBytes)); err != nil {
		return fmt.Errorf("write meta.json: %w", err)
	}

	return nil
}

// writeAtomic streams `r` to `<folder>/<name>.tmp`, fsyncs, then
// renames to `<folder>/<name>`. Returns the number of bytes written.
func writeAtomic(folder, name string, r io.Reader) (int, error) {
	final := filepath.Join(folder, name)
	tmp := final + ".tmp"

	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return 0, fmt.Errorf("open tmp: %w", err)
	}

	n, err := io.Copy(f, r)
	if err != nil {
		f.Close()
		os.Remove(tmp)

		return 0, fmt.Errorf("copy: %w", err)
	}

	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)

		return 0, fmt.Errorf("sync: %w", err)
	}

	if err := f.Close(); err != nil {
		os.Remove(tmp)

		return 0, fmt.Errorf("close: %w", err)
	}

	if err := os.Rename(tmp, final); err != nil {
		os.Remove(tmp)

		return 0, fmt.Errorf("rename: %w", err)
	}

	return int(n), nil
}

// CleanupOlderThan walks storage/poller/<streamType>/ and removes any
// folder whose meta.json mtime is older than cutoff. Folders without a
// meta.json (in-flight or crashed writes) are removed only if the
// folder itself is older than cutoff.
//
// streamType "" walks all stream types.
func CleanupOlderThan(root, streamType string, cutoff time.Time) error {
	base := filepath.Join(root, "poller")
	if streamType != "" {
		base = StreamRoot(root, streamType)
	}

	types, err := os.ReadDir(base)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}

		return err
	}

	for _, t := range types {
		if !t.IsDir() {
			continue
		}

		typeDir := base
		if streamType == "" {
			typeDir = filepath.Join(base, t.Name())
		}

		folders, err := os.ReadDir(typeDir)
		if err != nil {
			continue
		}

		for _, f := range folders {
			if !f.IsDir() {
				continue
			}

			full := filepath.Join(typeDir, f.Name())
			mtime, ok := folderMtime(full)
			if !ok {
				continue
			}

			if mtime.After(cutoff) {
				continue
			}

			_ = os.RemoveAll(full)
		}

		if streamType != "" {
			break
		}
	}

	return nil
}

// folderMtime returns the meta.json mtime if it exists, otherwise the
// folder's own mtime. The second return is false on any stat error.
func folderMtime(folder string) (time.Time, bool) {
	if info, err := os.Stat(filepath.Join(folder, "meta.json")); err == nil {
		return info.ModTime(), true
	}

	info, err := os.Stat(folder)
	if err != nil {
		return time.Time{}, false
	}

	return info.ModTime(), true
}

// bytesReader is a tiny adapter so callers can pass a []byte where a
// reader is expected without pulling in bytes.NewReader at every site.
func bytesReader(b []byte) io.Reader {
	return &byteSliceReader{data: b}
}

type byteSliceReader struct {
	data []byte
	off  int
}

func (r *byteSliceReader) Read(p []byte) (int, error) {
	if r.off >= len(r.data) {
		return 0, io.EOF
	}

	n := copy(p, r.data[r.off:])
	r.off += n

	return n, nil
}
