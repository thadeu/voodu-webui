# Licence token format

A voodu-webui Enterprise licence is a **JWS** — a signed JSON Web Token, RS256,
in compact serialisation. Nothing about it is voodu-specific: any JWT library in
any language can issue one, and the sections below include a worked example you
can reproduce byte for byte.

`lib/tasks/license.rake` is one implementation, not the definition. This file is
the definition.

## Shape

```
<base64url(header)>.<base64url(payload)>.<base64url(signature)>
```

**Header** — exactly this, no `typ`, no `kid`:

```json
{"alg":"RS256"}
```

**Payload**:

| claim | type | required | meaning |
|---|---|---|---|
| `sub` | string | yes | the customer. Shown in Settings → Plan and in logs |
| `exp` | integer | **yes** | expiry, seconds since epoch |
| `iat` | integer | no | issued at, seconds since epoch |
| `ent` | object | no | entitlement overrides; `{}` or absent means the licensed defaults |

`exp` is required and a token without it is rejected — otherwise one leaked
licence would be permanent.

**`ent` keys.** Anything not listed is ignored, so a typo behaves like the
default rather than silently granting:

| key | type | licensed default |
|---|---|---|
| `accounts` | integer or `null` | `null` (no limit) |
| `orgs` | integer or `null` | `null` |
| `member_invites` | integer or `null` | `null` |
| `retention_days` | integer | `90` |
| `postgres` | boolean | `true` |

`null` means no limit. Not for `retention_days`: the warehouse is SQLite on a
volume, so an unbounded window is a disk that fills and a container that dies.

**Signature** — RSASSA-PKCS1-v1_5 with SHA-256 (`RS256`) over
`base64url(header) + "." + base64url(payload)`, base64url **without padding**.

## Keys

The **public** key ships in the image at `config/license/public_key.pem` (SPKI
PEM, RSA-4096). The **private** key never enters this repository and lives
wherever you keep signing material.

Rotating means shipping a new public key in a new image, so old tokens stop
verifying on upgrade. There is no `kid` and no key list yet — add both before
you need to rotate, not during.

## Worked example

Reproducible with the **test** keypair in `test/fixtures/files/`, which exists
for exactly this and is not the production key.

Claims:

```json
{"sub":"acme-corp","iat":1788000000,"exp":1819536000,"ent":{"orgs":5,"retention_days":180}}
```

Token (2048-bit test key; production signatures are twice as long):

```
eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhY21lLWNvcnAiLCJpYXQiOjE3ODgwMDAwMDAsImV4cCI6MTgxOTUzNjAwMCwiZW50Ijp7Im9yZ3MiOjUsInJldGVudGlvbl9kYXlzIjoxODB9fQ.<signature>
```

The first two segments are deterministic: same claims and same key ordering
produce the same bytes in every language. That is how the Go implementation
below was checked — it emits a token identical to the Ruby one, and the app
accepts it.

Inspect any token the way the app sees it:

```sh
rake 'license:inspect[<token>]'
```

## Reference implementations

### Go (verified against the Ruby issuer — output is byte-identical)

```go
header  := b64([]byte(`{"alg":"RS256"}`))
payload := b64([]byte(`{"sub":"acme-corp","exp":1819536000}`))
signing := header + "." + payload

sum := sha256.Sum256([]byte(signing))
sig, _ := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])

token := signing + "." + b64(sig)
// b64 is base64.RawURLEncoding.EncodeToString — Raw, i.e. no padding.
```

### Node

```js
import jwt from "jsonwebtoken";

jwt.sign(
  { sub: "acme-corp", ent: { orgs: 5 } },
  privateKeyPem,
  { algorithm: "RS256", expiresIn: "365d" }
);
```

### Python

```python
import jwt, time

jwt.encode(
    {"sub": "acme-corp", "exp": int(time.time()) + 365 * 86400, "ent": {"orgs": 5}},
    private_key_pem,
    algorithm="RS256",
)
```

## Where the token lives

Either `VOODU_LICENSE` / `VOODU_LICENSE_FILE` in the environment, or a row in
`license_keys` written when someone pastes it into Settings → Plan. Both are
verified the same way; when both are present the one with the newer `iat` is in
force.

Activation stores the token, its subject and its dates, and who activated it —
one row per activation, so the history answers "when did they upgrade" without
costing anything.

## What the app checks, in order

1. Token absent → `:none`, the free tier. Not an error.
2. Signature or algorithm fails → `:invalid`. `alg` is pinned to RS256, so
   `alg:none` is a refusal rather than a free licence.
3. `exp` missing → `:invalid`.
4. `exp` in the future (plus 5 minutes of clock leeway) → `:valid`.
5. `exp` past, within 30 days → `:grace`. **Still entitled.**
6. Beyond that → `:lapsed`. Free tier.

Every branch produces a licence object. **None raises**, because a licence that
can fail closed can take a customer's monitoring down at 3am.

## Why JWS and not JWE

JWE encrypts; JWS signs. They solve different problems, and this one needs
signing.

The deciding constraint is **where verification happens**. A platform that
validates tokens on its own servers holds both halves of the key and can use
anything — symmetric HMAC, JWE, whatever. Here the verifier runs on the
**customer's** machine, so whatever it needs must ship inside the image:

- **JWE with a symmetric key** — the image would carry the key that decrypts
  *and* the ability to mint. Anyone who pulls the image issues their own
  licences. Strictly worse than no mechanism.
- **JWE with RSA-OAEP** — the image carries a private decryption key. That does
  not let anyone forge, but it does not authenticate the issuer either:
  encryption is not a signature. You would still need a JWS inside the JWE
  (a nested JWT) to know who issued it.
- **JWS with RS256** — the image carries only the public half. It can verify and
  cannot sign. This is the property that matters.

So JWE would buy one thing: the customer could not read their own entitlements.
That is a cost, not a feature. They should be able to see what they bought, and
support should be able to read a token pasted into a ticket without decrypting
anything.

And confidentiality would be theatre regardless: whoever runs the container can
read the process memory that holds the decrypted claims. The Elastic License 2.0
clause on circumventing licence-key functionality is what actually carries this
— see the reasoning in `.scratch/enterprise-license/PRD.md`.
