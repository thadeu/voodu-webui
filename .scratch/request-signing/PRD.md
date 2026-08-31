# Request signing on the PAT plane

Status: ready-for-human

## Context

Every request the WebUI makes to a controller carries the PAT whole:

```
Authorization: Bearer pat_abc12345_…
```

Capture one and you have that controller — deploy, exec, logs, everything the
PAT plane exposes. On a private network that is a tolerable risk. Across the
internet, which is what the hosted SaaS does, it is not: one intercepted request
is total compromise of a customer's box, and the customer has no way to know.

TLS would hide it. This does something different and cheaper: **it stops sending
the secret at all.** A captured request then yields one signature, for one
request, valid for a few minutes — not a credential.

The two are complementary and this is the one to do first. It kills the worst
outcome, it does not depend on deciding a CA or an issuance story, and it
behaves identically on a private network and on the open web.

## What it does and does not solve

| | today | with signing |
|---|---|---|
| captured credential | reusable forever, anywhere | nothing reusable on the wire |
| captured request replayed | — | refused (nonce + window) |
| captured request altered | — | refused (signature covers method, path, body) |
| captured response body | readable | **still readable** |

**Bodies stay in the clear.** Pod names, metrics and especially logs are the
customer's business data. Signing protects the credential; only TLS protects the
content. Anyone reading this plan as "we did security on the PAT plane" has read
it wrong.

## The scheme

```
Authorization: Voodu id=<pat-id>, ts=<unix-seconds>, nonce=<32 hex>, sig=<base64url>
```

**Canonical string**, newline-joined, no trailing newline:

```
v1
<METHOD uppercased>
<PATH, percent-encoded, no query>
<QUERY canonicalised — see below>
<lowercase hex sha256 of the raw request body, empty body = sha256("")>
<ts>
<nonce>
```

`v1` leads so the scheme can change without guessing which one a peer speaks.

**Query canonicalisation** is where cross-language signing usually breaks, so it
is specified rather than left to each HTTP library: sort parameters by name,
then by value; percent-encode name and value with RFC 3986 unreserved characters
left alone; join as `k=v` with `&`. Empty query is the empty string.

**The key** is the PAT's sha256, as the 64-character lowercase hex string, UTF-8
bytes — not the decoded digest, because "decode it" is one more thing two
languages can disagree about.

```
key = hex(sha256(plain PAT))
sig = base64url_nopad(HMAC-SHA256(key, canonical))
```

This is the part that costs nothing: the client holds the plain PAT and can
compute the hash; **the controller already stores exactly that string** as
`PAT.HashHex` (`internal/controller/pat.go`). No storage change, no migration,
no re-issuing existing PATs.

The trade-off, stated: today the stored hash is useless to a thief because it
has no preimage. Under this scheme it can forge requests to that controller.
Whoever has the controller's disk already has the controller, so the loss is
small — but it is a loss, and it is why the key is the hash rather than
something derived from it that only the client could hold.

## Replay

`ts` must be within ±5 minutes of the controller's clock — the same leeway the
licence verifier uses, and for the same reason: somebody else's clock is not
ours to trust to the second.

`nonce` is 16 random bytes, hex. The controller keeps seen nonces in memory for
the width of the window and refuses a repeat. In memory rather than etcd because
this is one write per request against a store that coordinates the cluster, to
prevent a replay that must land within five minutes on the same node. A
multi-node PAT plane would need shared state; there is one node today, and the
comment should say so rather than leaving the next person to discover it.

## Rolling out without a coordinated deploy

The controller and the WebUI are separate images on separate release cycles, so
the order matters more than the code:

**1. The controller accepts both.** `Bearer` keeps working exactly as it does;
`Voodu` is understood when offered. Ship and let it spread.

**2. The WebUI signs.** Both the Ruby client and the Go poller switch. A
controller that has not been upgraded still sees a scheme it does not know —
so the WebUI needs a fallback: on `401` from a `Voodu`-signed request, retry
once with `Bearer` and remember that endpoint speaks the old scheme.

**3. The operator turns off the old scheme.** `PAT_REQUIRE_SIGNATURE=1`,
default off. Only meaningful once everything talking to that controller is
upgraded, which is why it is the operator's switch and not a version check.

Skipping step 1 breaks every dashboard whose controller upgrades first. Skipping
the fallback in step 2 breaks every dashboard that upgrades first. Both are
"nothing works" failures, not degradations.

## Files

**clowk-voodu**

| file | change |
|---|---|
| `internal/controller/pat_signature.go` | **new** — canonical string, HMAC, nonce cache |
| `internal/controller/pat_middleware.go:112` | branch on the scheme; `Bearer` path untouched |
| `internal/controller/server.go` | `PATRequireSignature` config, default false |

**voodu-webui**

| file | change |
|---|---|
| `app/services/voodu/signature.rb` | **new** — the canonical string and HMAC, one place |
| `app/services/voodu/client.rb:344,359` | sign instead of Bearer; 401 fallback |
| `gems/poller/src/client/voodu.go:99,250` | same, in Go |

Five signing sites across two languages, one verification site. The canonical
string must be built in exactly one function per language, or the sites drift
and only some requests fail.

## The test that matters

Cross-language agreement, pinned the way the licence format was: **a fixed
input, and Ruby, Go and the controller must produce the same signature, byte for
byte.**

```
method=POST path=/api/pat/v1/pods/web-1/restart query="" body={} ts=1788000000
nonce=0123456789abcdef0123456789abcdef key=<known hash>
→ sig=<recorded>
```

That vector goes in all three test suites. Without it, the first disagreement
shows up as an intermittent 401 in production and gets blamed on the network.

Plus, per side: a replayed nonce is refused; a stale `ts` is refused; a body
altered after signing is refused; a path altered after signing is refused;
`Bearer` still works while the compatibility window is open.

## Armadilhas

| armadilha | trava |
|---|---|
| Ruby and Go disagree on query encoding | the shared vector above, in both suites |
| Proxy rewrites the path, breaking the signature | sign the path the client sent; document that a rewriting proxy in front of the PAT plane is not supported |
| Body read twice (signing, then sending) | sign from the serialised bytes actually sent, never re-serialise |
| Streaming requests have no complete body to hash | hash the empty body and include the path — log tailing has no body anyway |
| Clock drift on a customer box | ±5 min, and the 401 says which side is out of range rather than a generic refusal |
| Nonce cache grows without bound | bounded by the window; evict on read, and cap the map |
| Someone logs the Authorization header | it is no longer a secret — that is the point — but the PAT still is, and `HashPAT` output now is too |

## What NOT to do

- **Do not sign the response.** The client is not a trust anchor and it buys
  nothing here.
- **Do not put the nonce cache in etcd.** One write per request to the cluster
  store, to stop a replay that must land within five minutes on the same node.
- **Do not remove the Bearer path in the same release** that adds signing.
- **Do not treat this as TLS.** Bodies are still in the clear; see the table at
  the top.
- **Do not derive the key from anything the controller cannot compute.** It only
  ever has the hash — a scheme needing the plaintext means changing how PATs are
  stored, which is a different and much larger change.

## Verification

```sh
# clowk-voodu
go test ./internal/controller/...

# voodu-webui
bin/rails test test/services/voodu/signature_test.rb
(cd gems/poller/src && go test ./client/...)
```

End to end, against a real controller: register a server, watch the dashboard
fill, then `tcpdump` the PAT plane and confirm the header carries a signature
and no token. Then flip `PAT_REQUIRE_SIGNATURE=1` and confirm an old client gets
401 while the current one keeps working.

## Em aberto

- Whether `restart` (the only action today) should carry a shorter window than
  reads.
- Whether the WebUI should surface "this controller still speaks the old
  scheme" in the UI, or only in logs.
