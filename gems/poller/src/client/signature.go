package client

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Proving we hold a PAT without ever sending it.
//
// The PAT used to ride in every request as `Authorization: Bearer`, so one
// intercepted request was total control of that controller. Now each request
// carries an HMAC over what the request IS — method, path, query, body — plus
// a timestamp and nonce that make it good once.
//
// The key is the PAT's sha256 as a 64-char lowercase hex STRING, hashed as its
// UTF-8 bytes rather than the decoded digest: "decode it first" is one more
// thing two languages can disagree about, and this is the same string the
// controller already stores.
//
// This file must agree BYTE FOR BYTE with app/services/voodu/signature.rb.
// Where they drift is query encoding, and it drifts into an intermittent 401
// that gets blamed on the network — so both suites pin the same vector.
const (
	sigScheme  = "Voodu"
	sigVersion = "v1"
)

// SignatureHeader builds the Authorization value for one request.
func SignatureHeader(pat, method, path string, query url.Values, body []byte) (string, error) {
	nonce, err := newNonce()
	if err != nil {
		return "", err
	}

	return signatureHeaderAt(pat, method, path, query, body, time.Now().Unix(), nonce), nil
}

// Separated so tests can pin a timestamp and nonce against the Ruby vector.
func signatureHeaderAt(pat, method, path string, query url.Values, body []byte, ts int64, nonce string) string {
	stamp := strconv.FormatInt(ts, 10)
	canonical := canonicalString(method, path, query, body, stamp, nonce)
	sig := signCanonical(patKey(pat), canonical)

	return fmt.Sprintf("%s id=%s, ts=%s, nonce=%s, sig=%s", sigScheme, patID(pat), stamp, nonce, sig)
}

func canonicalString(method, path string, query url.Values, body []byte, ts, nonce string) string {
	bodySum := sha256.Sum256(body)

	return strings.Join([]string{
		sigVersion,
		strings.ToUpper(method),
		path,
		canonicalQuery(query),
		hex.EncodeToString(bodySum[:]),
		ts,
		nonce,
	}, "\n")
}

// Sorted by name then value, each side percent-encoded with RFC 3986
// unreserved characters left alone. Specified rather than delegated to
// url.Values.Encode(), which sorts by key but leaves repeated values in
// insertion order and escapes a space as `+`.
func canonicalQuery(query url.Values) string {
	if len(query) == 0 {
		return ""
	}

	pairs := make([]string, 0, len(query))

	for key, values := range query {
		for _, value := range values {
			pairs = append(pairs, escapeRFC3986(key)+"="+escapeRFC3986(value))
		}
	}

	sort.Strings(pairs)

	return strings.Join(pairs, "&")
}

// url.QueryEscape turns a space into `+`; RFC 3986 wants `%20`. Ruby's
// ERB::Util.url_encode does the latter, so this matches it.
func escapeRFC3986(value string) string {
	escaped := url.QueryEscape(value)
	escaped = strings.ReplaceAll(escaped, "+", "%20")
	// QueryEscape leaves these alone in some Go versions and escapes them in
	// others; RFC 3986 calls all four unreserved.
	replacer := strings.NewReplacer("%7E", "~", "%2A", "*")

	return replacer.Replace(escaped)
}

func signCanonical(key, canonical string) string {
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(canonical))

	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// The 64-char lowercase hex of sha256(plain) — the same string the controller
// holds as PAT.HashHex.
func patKey(pat string) string {
	sum := sha256.Sum256([]byte(pat))

	return hex.EncodeToString(sum[:])
}

// The token is `pat_` + 28 base64url characters; the first 6 of those are the
// public ID the controller keys its record by. Mirrors ParsePATToken in the
// controller, length and alphabet checks included — sending an id it will
// reject is a 401 with no explanation rather than a clean local failure.
const (
	tokenPrefix  = "pat_"
	tokenBodyLen = 28
	tokenIDLen   = 6
)

func patID(pat string) string {
	if !strings.HasPrefix(pat, tokenPrefix) {
		return ""
	}

	body := strings.TrimPrefix(pat, tokenPrefix)
	if len(body) != tokenBodyLen {
		return ""
	}

	for i := 0; i < len(body); i++ {
		c := body[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return ""
		}
	}

	return body[:tokenIDLen]
}

func newNonce() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("signature nonce: %w", err)
	}

	return hex.EncodeToString(buf), nil
}

// SignRequest sets the Authorization header on an already-built request.
//
// Reads the method, path and query off the request itself rather than taking
// them as arguments: the signature has to cover what is actually sent, and a
// caller passing a path that has since been rewritten produces a 401 that
// looks like an auth problem and is a plumbing problem.
//
// Bodies on this plane are always empty (every call is a GET or a bodiless
// POST), so nil is signed. A future call with a body must hash the exact bytes
// it sends, not a re-serialisation of them.
func SignRequest(req *http.Request, pat string) error {
	header, err := signRequestAt(req, pat, time.Now().Unix())
	if err != nil {
		return err
	}

	req.Header.Set("Authorization", header)

	return nil
}

func signRequestAt(req *http.Request, pat string, ts int64) (string, error) {
	nonce, err := newNonce()
	if err != nil {
		return "", err
	}

	return signatureHeaderAt(pat, req.Method, req.URL.Path, req.URL.Query(), nil, ts, nonce), nil
}
