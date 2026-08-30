# Self-hosted

One `docker run`, one volume, no environment variables. This is the default
shape and a complete product: everything the dashboard does, for one operator,
on one box.

```sh
docker run -d --name voodu-webui \
  -p 3000:3000 -v voodu:/rails/storage \
  ghcr.io/thadeu/voodu-webui
```

Open `http://<host>:3000` and register your first server. There is no sign-in
screen, and that is deliberate — see below.

## The perimeter is the door

With no `CLOWK_ENABLED`, the app asks for no credentials. Every request runs as
one local operator holding owner rights, on the assumption that something in
front of it already authenticated the caller: Twingate, WireGuard, Cloudflare
Access, an SSH tunnel.

**Owner rights include reading every server's access token, and that token is
the controller** — deploy, exec, logs, on every box this dashboard manages.
Publishing port 3000 to the internet with sign-in off does not leak a dashboard;
it hands over the infrastructure.

The app says so itself rather than assuming you read this: a warning at boot in
`docker logs`, and a banner on every page once a request arrives from a public
address. If your access proxy forwards real client IPs (Cloudflare Access does;
Twingate and most VPNs do not), silence the banner with
`VOODU_TRUSTED_PERIMETER=1` — it says the perimeter is there, it does not
create one.

Anonymous mode is not a bypass. It provisions a real user with a real owner
membership, so authorization runs through the same single path every request
uses; there is simply one membership to find.

To require per-person sign-in instead, see [sso.md](sso.md).

## What the volume holds

Everything. Losing it is the one failure this shape has no answer for.

| path | why it matters |
|---|---|
| `production*.sqlite3` (6 files) | orgs, servers, encrypted PATs, telemetry |
| `.ar_encryption.env` | **loses this and every stored PAT is unreadable** |
| `.secret_key_base` | sessions; losing it signs everyone out |
| `logs/<server_id>/` | NDJSON log tree |
| `thruster/` | Let's Encrypt certificates |

The encryption keys are worth more than the databases. A restored database
without them is a list of servers you can no longer talk to.

## Backups

Snapshot the volume, or take a consistent copy without stopping the container:

```sh
docker exec voodu-webui sh -c \
  'for db in /rails/storage/production*.sqlite3; do
     sqlite3 "$db" ".backup /rails/storage/backup-$(basename "$db")"
   done'
docker cp voodu-webui:/rails/storage/.ar_encryption.env ./
```

`.backup` matters: copying a SQLite file mid-write gives you a file that may not
open.

## HTTPS and a password prompt

Both are opt-in. `TLS_DOMAIN` gets a Let's Encrypt certificate automatically —
see [tls.md](tls.md) for the three conditions and the failure modes — and
`docker-compose.auth.yml` adds a Caddy Basic Auth overlay. Neither replaces the
perimeter: Basic Auth in particular is a shared password, not identity.

## Upgrading

```sh
docker compose pull && docker compose up -d
```

Migrations run on boot (`db:prepare` in the entrypoint) and are idempotent.
Keep the volume and nothing else is needed.

One thing an upgrade will never do is remove authentication: if
`CLOWK_PUBLISHABLE_KEY` is set, sign-in stays on even when `CLOWK_ENABLED` is
not.

## When one operator stops being enough

- More than one person, each with their own identity → [sso.md](sso.md)
- More than one org, longer retention, your own Postgres →
  [enterprise.md](enterprise.md)
