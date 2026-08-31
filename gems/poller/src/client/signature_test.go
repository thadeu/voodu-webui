package client

import (
	"net/http"
	"net/url"
	"strings"
	"testing"
)

// The same vector is pinned in two other implementations — the Ruby client
// (voodu-webui test/services/voodu/signature_test.rb) and the controller
// (clowk-voodu internal/controller/pat_signature_test.go). Three languages
// agreeing is the point: two of them drifting on query encoding shows up as an
// intermittent 401 that gets blamed on the network.
const (
	vectorPAT   = "pat_Ab3-_xYz01234567890123456789"
	vectorTS    = 1788000000
	vectorNonce = "00000000000000000000000000000000"
)

func TestSignatureVector_Simple(t *testing.T) {
	got := signatureHeaderAt(vectorPAT, "GET", "/api/pat/v1/pods", nil, nil, vectorTS, vectorNonce)
	want := "Voodu id=Ab3-_x, ts=1788000000, nonce=" + vectorNonce +
		", sig=4sepjmSvGAV5neJHO_ABgV80oodUrAfMdyaCb2IEQYE"

	if got != want {
		t.Errorf("signature drift.\n got %s\nwant %s", got, want)
	}
}

func TestSignatureVector_QueryAndBody(t *testing.T) {
	query := url.Values{"scope": {"fsw"}, "since": {"a b"}}
	got := signatureHeaderAt(vectorPAT, "POST", "/api/pat/v1/pods/web-1/restart", query,
		[]byte(`{"force":true}`), vectorTS, "0123456789abcdef0123456789abcdef")

	if !strings.Contains(got, "sig=P_JpjmCtmcQ2_04vWEldQoqU9uIZ_Z4U75LT4jbyi5A") {
		t.Errorf("signature drift: %s", got)
	}
}

// Where Go and Ruby part company: url.QueryEscape spells a space `+`, RFC 3986
// wants `%20`, and only one of them matches the controller.
func TestCanonicalQuery_EscapesSpaceAsPercent20(t *testing.T) {
	if got, want := canonicalQuery(url.Values{"since": {"a b"}}), "since=a%20b"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestCanonicalQuery_SortsRepeatedValues(t *testing.T) {
	got := canonicalQuery(url.Values{"pod": {"web-2", "web-1"}, "a": {"1"}})

	if want := "a=1&pod=web-1&pod=web-2"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// Mirrors ParsePATToken in the controller: `pat_` + exactly 28 base64url
// characters, id = the first 6. Sending an id the controller will reject is a
// 401 with no explanation rather than a clean local failure.
func TestPatID(t *testing.T) {
	cases := map[string]string{
		vectorPAT:                        "Ab3-_x",
		"pat-alpha-secret":               "",
		"pat_tooshort":                   "",
		"pat_" + strings.Repeat("!", 28): "",
		"":                               "",
	}

	for token, want := range cases {
		if got := patID(token); got != want {
			t.Errorf("patID(%q) = %q, want %q", token, got, want)
		}
	}
}

// ── What a capturer cannot do ──────────────────────────────────────────

func TestSignRequest_PATNeverOnTheWire(t *testing.T) {
	req, _ := http.NewRequest("GET", "http://box:8687/api/pat/v1/pods", nil)

	if err := SignRequest(req, vectorPAT); err != nil {
		t.Fatal(err)
	}

	auth := req.Header.Get("Authorization")
	if strings.Contains(auth, vectorPAT) || strings.Contains(auth, "Yz0123456789") {
		t.Errorf("the PAT travelled: %q", auth)
	}
}

func TestSignature_CoversMethodAndPath(t *testing.T) {
	read := signatureHeaderAt(vectorPAT, "GET", "/api/pat/v1/pods", nil, nil, vectorTS, vectorNonce)
	write := signatureHeaderAt(vectorPAT, "POST", "/api/pat/v1/pods", nil, nil, vectorTS, vectorNonce)
	other := signatureHeaderAt(vectorPAT, "POST", "/api/pat/v1/pods/db-1/restart", nil, nil, vectorTS, vectorNonce)

	if read == write {
		t.Error("a captured read could be replayed as a write")
	}

	if write == other {
		t.Error("a captured restart could be aimed at another pod")
	}
}

func TestSignRequest_NonceIsUnique(t *testing.T) {
	seen := map[string]bool{}

	for i := 0; i < 5; i++ {
		req, _ := http.NewRequest("GET", "http://box:8687/api/pat/v1/pods", nil)
		if err := SignRequest(req, vectorPAT); err != nil {
			t.Fatal(err)
		}

		auth := req.Header.Get("Authorization")
		if seen[auth] {
			t.Fatal("two requests signed identically — the controller refuses the second as a replay")
		}

		seen[auth] = true
	}
}
