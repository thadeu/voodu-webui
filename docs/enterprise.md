# Enterprise

The free tier is a complete product: one account, one org, one operator. A
licence lifts the limits.

| | Free | Enterprise |
|---|---|---|
| accounts | 1 | unlimited |
| orgs | 1 | unlimited |
| invited members | none | unlimited |
| searchable window | 3 days | 90 by default, set per licence |
| control plane in Postgres | — | ✓ |

## Activating

Paste the token at **`/ops/license`** and the installation is Enterprise on the
next request. No redeploy, no restart.

Or set it in the environment, which does need a restart:

```sh
VOODU_LICENSE=eyJhbGciOiJSUzI1NiJ9…
VOODU_LICENSE_FILE=/rails/storage/license.jwt   # if you prefer secrets as files
```

When both exist, **the newer token wins** by its `iat`. That is the only rule
that serves an operator who sets the env var once, one who renews through the
UI, and one who keeps compose in git — without either side silently undoing the
other.

Renewal is the same act: paste the new one. Each activation is a new row, so
`/ops/license` shows the history — when this installation became Enterprise,
under whose name, and who pasted it.

## Verified offline

The public key ships in the image; nothing calls home. A licence works in a
closed network, and our availability is not part of your risk.

The token is a plain RS256 JWT — see
[license-token-format.md](license-token-format.md) if you are issuing them.

## What a lapse can and cannot do

Absent, malformed and expired are ordinary states. **None of them stops the
app**; all resolve to the free tier, and `/ops/license` says which and why.
Expiry has 30 days of grace before even that.

What changes after grace: no new orgs, no new invitations, and the searchable
window narrows. What does **not** change:

- **Nothing is deleted.** `VOODU_RETENTION_DAYS` decides how long telemetry
  stays on disk and the licence never touches it. A lapse hides history;
  renewing reveals the same bytes. See [database.md](database.md).
- **Postgres keeps being read.** If your control plane is in Postgres and the
  licence lapses, the app keeps serving it and says so in the UI. Locking an
  operator out of their own database is not a term we are willing to enforce.
- **Existing orgs and members stay.** Only the *next* one is refused.

That the enforcement stops there is deliberate. Anyone running the image can
modify it, so a harder technical gate would inconvenience customers without
stopping anyone — which is what the Elastic License 2.0 clause on circumventing
licence-key functionality is for.

## Two things worth knowing before you buy

**A licence cannot be revoked.** Being offline, it is valid until its `exp`.
Ending a subscription means declining to renew, not switching something off.

**Postgres is an option, not a migration.** The licence permits `DATABASE_URL`;
taking it up is a fresh start with an empty database. See
[database.md](database.md) before you set it.
