# Authorization: Voodu

Every request the WebUI makes to a controller's PAT plane is **signed**. The
token itself never travels.

```
Authorization: Voodu id=Ab3-_x, ts=1788138276, nonce=734333e41218c14fdc2c7d3dbacd65e0, sig=yD1ACypD5wj25N1G_QpFhMKMbmBMJWEmAGj9cQPdCDA
```

Nothing about the scheme is secret — this page is the whole of it. What is
secret is the PAT, and the point is that it stays where it is.

## Why it replaced Bearer

The PAT used to ride in every request:

```
Authorization: Bearer pat_Ab3-_xYz01234567890123456789
```

Capture one request and you had that controller — deploy, exec, logs, for as
long as the token lived. On a private network that is a tolerable risk. Across
the internet, which is what a hosted dashboard does, it is not: one intercepted
request is total compromise of a customer's box, and nobody would know.

Signing does not hide the credential. It stops sending one.

## The header

| field | what it is |
|---|---|
| `id` | the public first 6 characters of the token body — how the controller finds the record |
| `ts` | unix seconds; must be within ±5 minutes of the controller's clock |
| `nonce` | 16 random bytes, hex; refused if seen again inside the window |
| `sig` | base64url (unpadded) HMAC-SHA256 over the canonical string below |

## The canonical string

Newline-joined, no trailing newline:

```
v1
<METHOD, uppercased>
<PATH, no query>
<QUERY, canonicalised — see below>
<lowercase hex sha256 of the raw body; empty body hashes the empty string>
<ts>
<nonce>
```

`v1` leads so the scheme can change without either side guessing which one the
other speaks.

**Query canonicalisation** is spelled out rather than left to each HTTP library,
because this is exactly where two implementations drift: sort the encoded
`k=v` pairs, percent-encode both sides leaving RFC 3986 unreserved characters
alone, join with `&`. Empty query is the empty string.

The rule that catches people: **a space is `%20`, not `+`.** Ruby's `CGI.escape`
and Go's `url.QueryEscape` both produce `+`, and both are wrong here.

## The key

```
key = hex(sha256(plain PAT))          # 64 lowercase hex characters
sig = base64url_nopad(HMAC-SHA256(key, canonical))
```

The key is that hex **string**, hashed as its UTF-8 bytes — not the decoded
digest. "Decode it first" is one more thing two implementations can disagree
about, and there is nothing to gain from it.

This is why the scheme cost nothing to adopt: the client holds the plain token
and can hash it, and **the controller already stores exactly that hash**. No
storage change, no migration, not one PAT re-issued.

## Signing it yourself

Four implementations exist and all produce the same bytes. The shell one is
here because it is the one you can paste into a terminal at 2am:

```sh
PAT="pat_Ab3-_xYz01234567890123456789"
TS=$(date +%s)
NONCE=$(openssl rand -hex 16)

KEY=$(printf '%s' "$PAT" | shasum -a 256 | cut -d' ' -f1)
BODY_HASH=$(printf '' | shasum -a 256 | cut -d' ' -f1)

CANON=$(printf 'v1\nGET\n/api/pat/v1/pods\n\n%s\n%s\n%s' "$BODY_HASH" "$TS" "$NONCE")
SIG=$(printf '%s' "$CANON" | openssl dgst -sha256 -hmac "$KEY" -binary \
      | base64 | tr '+/' '-_' | tr -d '=')

curl -H "Authorization: Voodu id=${PAT:4:6}, ts=$TS, nonce=$NONCE, sig=$SIG" \
     http://10.0.0.1:8687/api/pat/v1/pods
```

The other three:

- `app/services/voodu/signature.rb` — the Ruby client
- `gems/poller/src/client/signature.go` — the Go poller
- `internal/controller/pat_signature.go` in clowk-voodu — the verifier

All four are pinned to the same test vector. Change the canonical string and
every suite fails, which is the intended cost.

## What the controller checks, in order

1. Parse the header. Malformed → 401, with no hint about which field.
2. `ts` outside ±5 minutes → 401. Checked first: it is the cheapest, and the
   only failure an operator can actually fix.
3. Look the PAT up by `id`. Unknown → 401.
4. Buffer the body, rebuild the canonical string from the request as received,
   and compare the HMAC in constant time. Mismatch → 401.
5. Nonce already spent → 401. Checked last, so nobody can burn nonces they
   cannot sign for.
6. Scope insufficient → 403.

Every refusal returns the same message. Telling a caller which field was wrong
tells an attacker the same thing.

## What this protects, and what it does not

| | before | now |
|---|---|---|
| traffic capture yields a reusable credential | yes | **no** |
| a captured request replayed | possible | **refused** |
| a captured `GET` turned into a `restart` | possible | **refused** |
| the content of requests and responses | readable | **still readable** |
| a PAT stolen at rest (database, backup, screen) | full control | **full control** |

The last two rows matter as much as the first three.

**Bodies travel in the clear.** Pod names, metrics and especially logs are the
customer's business data. Someone listening cannot *ask* the controller for
anything, but they can watch everything the dashboard asks for — and the poller
asks every 15 seconds. Only TLS closes that.

**A stolen PAT is still a PAT.** The scheme is public and the key derivation is
public; anyone holding the token signs exactly as the dashboard does. What
changed is where it can be stolen from — off the wire, no longer; off a disk or
a screen, unchanged.

## Troubleshooting

| symptom | almost always |
|---|---|
| every request 401s after upgrading one side | the two speak different schemes; Bearer is gone, so both must be current |
| 401 only from one machine | its clock is more than 5 minutes out |
| 401 only on requests with a query | a space encoded as `+` instead of `%20` |
| 401 on the second identical request | the nonce was reused; it must be random per request |
| 401 after a proxy was added | the proxy rewrote the path; the signature covers the path the client sent |
