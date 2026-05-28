package client

import (
	"testing"
	"time"
)

func TestParseLine_PrefixAndTimestamp(t *testing.T) {
	raw := []byte("[newcall-api.e41c] 2026-05-28T12:34:56.789Z hello world")

	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "newcall-api.e41c" {
		t.Errorf("pod=%q, want newcall-api.e41c", pod)
	}
	want, _ := time.Parse(time.RFC3339Nano, "2026-05-28T12:34:56.789Z")
	if !ts.Equal(want) {
		t.Errorf("ts=%v, want %v", ts, want)
	}
	if body != "hello world" {
		t.Errorf("body=%q, want hello world", body)
	}
}

func TestParseLine_PrefixOnly_NoTimestamp(t *testing.T) {
	raw := []byte("[newcall-api.e41c] plain body without timestamp")

	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "newcall-api.e41c" {
		t.Errorf("pod=%q", pod)
	}
	if !ts.IsZero() {
		t.Errorf("ts=%v, want zero", ts)
	}
	if body != "plain body without timestamp" {
		t.Errorf("body=%q", body)
	}
}

func TestParseLine_TimestampOnly_NoPrefix(t *testing.T) {
	raw := []byte("2026-05-28T12:34:56Z singleton body")

	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "" {
		t.Errorf("pod=%q, want empty", pod)
	}
	want, _ := time.Parse(time.RFC3339, "2026-05-28T12:34:56Z")
	if !ts.Equal(want) {
		t.Errorf("ts=%v, want %v", ts, want)
	}
	if body != "singleton body" {
		t.Errorf("body=%q", body)
	}
}

func TestParseLine_PlainBody(t *testing.T) {
	raw := []byte("just text, no metadata")

	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "" {
		t.Errorf("pod=%q, want empty", pod)
	}
	if !ts.IsZero() {
		t.Errorf("ts=%v, want zero", ts)
	}
	if body != "just text, no metadata" {
		t.Errorf("body=%q", body)
	}
}

func TestParseLine_EmptyLine_NotOK(t *testing.T) {
	if _, _, _, ok := ParseLine([]byte("")); ok {
		t.Error("empty line should be ok=false (heartbeat)")
	}
	if _, _, _, ok := ParseLine([]byte("\n")); ok {
		t.Error("newline-only line should be ok=false")
	}
}

func TestParseLine_TrimsTrailingCRLF(t *testing.T) {
	raw := []byte("[pod-x] body line\r\n")
	pod, _, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "pod-x" {
		t.Errorf("pod=%q", pod)
	}
	if body != "body line" {
		t.Errorf("body=%q", body)
	}
}

func TestParseLine_BracketInBody_NotConsumed(t *testing.T) {
	// Controller's per-pod stream-error suffix: "[pod] [stream error] EOF"
	raw := []byte("[pod-a] [stream error] EOF")
	pod, ts, body, ok := ParseLine(raw)
	if !ok {
		t.Fatal("ok=false")
	}
	if pod != "pod-a" {
		t.Errorf("pod=%q", pod)
	}
	if !ts.IsZero() {
		t.Errorf("ts=%v, want zero", ts)
	}
	if body != "[stream error] EOF" {
		t.Errorf("body=%q", body)
	}
}
