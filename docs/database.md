# Databases

Six logical databases. `DATABASE_URL` moves **one** of them.

| database | default | with `DATABASE_URL` | holds |
|---|---|---|---|
| primary | SQLite | **Postgres** | orgs, users, accounts, memberships, servers, encrypted PATs |
| cache | SQLite | SQLite | sessions and cache |
| queue | SQLite | SQLite | background jobs |
| cable | SQLite | SQLite | ephemeral |
| metrics | SQLite | SQLite | telemetry |
| hep | SQLite | SQLite | SIP capture |

```sh
DATABASE_URL=postgres://voodu:secret@10.0.0.5:5432/voodu
```

You do not edit `config/database.yml`. Rails routes `DATABASE_URL` to the
`primary` entry natively and replaces that entry's whole configuration — the
YAML keeps declaring SQLite and the URL overrides adapter, host and database
name on top of it.

First boot needs nothing else: the entrypoint's `db:prepare` creates the
Postgres database if the role may (`CREATEDB`), loads the schema, then creates
the five SQLite files. Pre-create the database by hand if you would rather not
grant `CREATEDB`.

## Why the warehouse stays on SQLite

Not for lack of trying. `metric_samples` and `hep_messages` are built on ground
only SQLite has: generated columns computed with `json_extract` and `strftime`,
a `REGEXP` operator registered on the connection, `COLLATE NOCASE`. Postgres
could not create those tables at all — and PG 18's virtual columns do not change
it, since they cannot be indexed and these columns exist to be indexed.

**So the storage volume is still required with Postgres.** Losing it costs the
telemetry window (which the poller rebuilds), every session, and any pending
job. It does not cost an org, a user or a PAT.

## Switching is a fresh start, not a migration

Setting `DATABASE_URL` on an installation that has been running gives you an
**empty** database. Orgs, servers and PATs are re-registered by hand. That is a
deliberate contract: the control plane is small, and a reliable cross-adapter
migration is a great deal of machinery for a few minutes of typing.

The volume is not fresh, and that is the part worth knowing. Telemetry is keyed
by a bare `server_id` with no foreign key to `servers`, so when a Postgres
sequence restarts at 1 the first server you register afterwards would inherit
the previous first server's history — a web box convincingly reporting a
database's CPU. The entrypoint clears that on boot: rows and log directories
matching no server are unreachable anyway, so they go before they can be
mistaken for someone else's. Nothing you can still reach is touched.

Your licence lives in the primary database too, so re-paste it at
`/ops/license` after switching.

## Retention: two numbers

```sh
VOODU_RETENTION_DAYS=90
```

**How long telemetry stays on disk.** Yours to set, and never touched by the
licence — an entitlement that could shrink this would delete your history the
day a renewal ran late.

**How far back you can search** is the other number, and that one the licence
caps: 3 days on the free tier, 90 by default with a licence. You cannot search
what was not kept, so an Enterprise install wanting 90 searchable days sets both.
Buying the entitlement does not silently start consuming your disk.

## Backups

Two halves, two procedures.

```sh
pg_dump "$DATABASE_URL" -Fc -f voodu-$(date +%F).dump
```

…plus the volume, for the five SQLite files and the encryption keys — see
[self-hosted.md](self-hosted.md#backups). The halves can drift apart in time
without harm: warehouse rows for a server that no longer exists are simply never
read.

## MySQL and other adapters

Postgres today, and the schema is portable enough that another might work — but
`db/schema.rb` carries two partial indexes, and MySQL has no partial indexes at
all. That is a real blocker rather than a missing driver.
