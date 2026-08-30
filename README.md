# voodu-webui

Self-hosted web UI for the [voodu](https://github.com/thadeu/clowk-voodu) PaaS controller.
Register your servers, watch pods, stream logs, browse metrics, and run common
operator commands without SSHing in for every check.

## What you get

- **Multi-server dashboard.** One URL prefix per server (`/<server-key>/...`). Switch
  servers by changing the URL — bookmarks and parallel tabs Just Work.
- **Live pods / logs / metrics.** Drawer-mode log following, sparklines + range pills
  on charts, current values stable across time ranges.
- **⌘K command palette.** Global across every registered server, cached client-side.
- **External API dashboards.** Build a Table or Area/Number chart from any HTTP endpoint
  with a small JSON mapping — see [docs/http-source-mapping.md](docs/http-source-mapping.md).
- **PAT auth, encrypted at rest.** Each server stores a personal access token used to
  talk to its `voodu` controller; tokens are stored as `pat_ciphertext`, encrypted at
  rest via ActiveRecord Encryption, in whichever database holds the control plane.
- **Single container.** Rails 8.1 with the Solid stack (`solid_cache`, `solid_queue`,
  `solid_cable`) — no Redis, no sidekiq, no separate worker pod. Add a volume, you're
  done.
- **Two deployment shapes, one image.** Out of the box: SQLite, no sign-in, meant to
  sit behind your VPN or access proxy. Set two env vars and the same image becomes a
  multi-tenant install with per-person sign-in and Postgres holding the control plane.
  See [Deployment shapes](#deployment-shapes).

## Quick start

The image is published as `ghcr.io/thadeu/voodu-webui:latest`. Internally it always
listens on **port 3000**. External port is whatever you want.

### docker run

```sh
docker run -d --name voodu-webui \
  -p 3000:3000 \
  -v voodu_webui_storage:/rails/storage \
  --add-host=host.docker.internal:host-gateway \
  --restart unless-stopped \
  ghcr.io/thadeu/voodu-webui:latest

# Any external port — internal stays 3000
docker run -d -p 80:3000    -v voodu_webui_storage:/rails/storage --add-host=host.docker.internal:host-gateway ghcr.io/thadeu/voodu-webui:latest
docker run -d -p 1886:3000  -v voodu_webui_storage:/rails/storage --add-host=host.docker.internal:host-gateway ghcr.io/thadeu/voodu-webui:latest
docker run -d -p 18687:3000 -v voodu_webui_storage:/rails/storage --add-host=host.docker.internal:host-gateway ghcr.io/thadeu/voodu-webui:latest

# With HTTPS: Thruster gets a Let's Encrypt cert for TLS_DOMAIN and redirects
# HTTP -> HTTPS. Needs an A record pointing here and host ports 80 + 443 open.
docker run -d -p 80:3000 -p 443:443 -e TLS_DOMAIN=console.example.com \
  -v voodu_webui_storage:/rails/storage --add-host=host.docker.internal:host-gateway ghcr.io/thadeu/voodu-webui:latest

# Logs / lifecycle
docker logs -f voodu-webui
docker stop voodu-webui && docker start voodu-webui
docker pull ghcr.io/thadeu/voodu-webui:latest && docker rm -f voodu-webui  # then re-run
```

`--add-host=host.docker.internal:host-gateway` is required on Linux for
`host.docker.internal` to resolve. Docker Desktop on macOS/Windows already provides it
natively, so the flag is a no-op there — leave it in for portability.

### docker-compose

```sh
curl -O https://raw.githubusercontent.com/thadeu/voodu-webui/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/thadeu/voodu-webui/main/.env.example
mv .env.example .env
# edit .env: host ports, TLS_DOMAIN, Basic Auth
docker compose up -d

# Lifecycle
docker compose logs -f
docker compose pull && docker compose up -d   # upgrade to a newer image
docker compose down
```

The bundled `docker-compose.yml` already wires the storage volume, the
`host.docker.internal` host alias, and an isolated default network
(`voodu_webui_network`). Other containers on your host won't reach it on the Docker
network — only through the published host port.

By default it publishes host `80` -> container `3000` and host `443` -> container
`443` (`HOST_HTTP_PORT` / `HOST_HTTPS_PORT` in `.env`). The container side stays on
`3000`: the image `HEALTHCHECK` curls `http://localhost:3000/up`.

### HTTPS

The image bundles Thruster, which provisions and renews a Let's Encrypt certificate
on its own. Set one variable:

```sh
# .env
TLS_DOMAIN=console.example.com
```

```sh
docker compose up -d
docker compose logs -f web | grep -i -E 'tls|acme|certificate'
```

Three things must be true before you set it, or the site goes dark — the HTTPS
listener has no certificate and HTTP only answers with a redirect to it:

1. An A/AAAA record for the name resolves to this host
2. Host ports 80 **and** 443 are open — 80 is where the ACME HTTP-01 challenge lands
3. Nothing else terminates TLS in front. A Cloudflare orange-cloud proxy breaks
   HTTP-01; use DNS-only, or leave `TLS_DOMAIN` empty and let Cloudflare hold the cert

Certificates persist in the storage volume (`/rails/storage/thruster`), so restarts
don't re-request them. While you're still fixing DNS or firewall rules, set
`ACME_DIRECTORY` to the Let's Encrypt staging endpoint so failures don't burn the
production rate limit. Leaving `TLS_DOMAIN` empty serves plain HTTP with no cert.

Mapping host `443` straight to container `3000` without `TLS_DOMAIN` is the common
mistake: the browser opens a TLS handshake against a plain HTTP listener and shows
`ERR_SSL_PROTOCOL_ERROR`.

### Basic Auth

The dashboard has no login screen. `docker-compose.auth.yml` puts Caddy in front of
it: Caddy terminates TLS, asks for a user and password, and proxies to the app over
the private compose network. In this mode the app publishes no host port at all, so
the prompt can't be walked around by hitting the host directly.

```sh
curl -O https://raw.githubusercontent.com/thadeu/voodu-webui/main/docker-compose.auth.yml
curl -O https://raw.githubusercontent.com/thadeu/voodu-webui/main/Caddyfile
```

```sh
# .env
TLS_DOMAIN=console.example.com
BASIC_AUTH_USER=voodu
BASIC_AUTH_PASSWORD=something-long
```

```sh
docker compose -f docker-compose.yml -f docker-compose.auth.yml up -d
```

Set `COMPOSE_FILE=docker-compose.yml:docker-compose.auth.yml` in `.env` to keep
typing plain `docker compose up -d`.

The password stays plain text in `.env` and is bcrypt-hashed at container boot, so
rotating it is one edit plus `docker compose up -d`. `/up` is excluded from the
prompt so healthchecks and uptime monitors keep working without credentials.

### Operator sign-in

**Off by default on a fresh install.** With no `CLOWK_ENABLED` and no
`CLOWK_PUBLISHABLE_KEY`, the app asks for no credentials:
every request runs as one local operator with owner rights. That is the intended
shape for a self-hosted install — the *perimeter* authenticates (Twingate,
WireGuard, Cloudflare Access, an SSH tunnel) and whoever reaches the port has
already proved who they are to it.

> **Read this before publishing the port.** Owner rights include reading each
> server's access token, and that token IS the controller: deploy, exec, logs, on
> every box this dashboard manages. Exposing port 3000 to the internet with
> sign-in off does not leak a dashboard, it hands over the infrastructure. The app
> warns at boot in `docker logs` and puts a banner on every page once a request
> arrives from a public address — silence it with `VOODU_TRUSTED_PERIMETER=1` only
> when a proxy that forwards real client IPs is genuinely in front.

Anonymous mode is not a bypass. It provisions a real user with a real owner
membership, so authorization keeps running through the one path every request
uses — there is simply exactly one membership to find.

**Upgrades never remove sign-in.** A publishable key with no `CLOWK_ENABLED`
keeps sign-in on: an install already configured for Clowk is one where somebody
chose it, and a release that read "unset" as "anonymous" would silently open
that dashboard to whoever reaches the port. Set `CLOWK_ENABLED=0` to go
anonymous deliberately.

**Turn sign-in on** for a multi-tenant install — several people, each reaching
only what a membership grants them. Either in the environment:

```sh
# .env
CLOWK_ENABLED=1
CLOWK_PUBLISHABLE_KEY=pk_live_...
```

**Or from Settings → Authentication**, if you decided you wanted it after
already running. Paste the publishable key and the address that will sign in,
and the next request asks for authentication.

That address matters: anonymous mode runs as one local operator, so the screen
hands the existing workspace over to it. Without that, the first real sign-in
would be a brand-new person with no membership, and every server would sit in an
org nobody could reach.

**The environment always wins**, and that is the way out. If a key saved here is
wrong you would be locked out of your own dashboard with no UI to fix it from —
restart with `CLOWK_ENABLED=0` and you are anonymous again, whatever is stored.

The app verifies the JWT Clowk issues and mirrors the subject onto a local
`users` row. With the flag on and no publishable key, it **refuses to boot**
rather than start unprotected.

Two optional companions:

- `CLOWK_SECRET_KEY` — server-to-server calls to the Clowk API and the legacy
  HS256 path. Verifying a current token does not need it: that runs against the
  published key set.
- `CLOWK_SUBDOMAIN_URL` — the instance's auth domain. Set it and the gem stops
  resolving it through `api.clowk.dev`, taking one network dependency off the
  path that authenticates every request (and off the JWKS fetch behind it).

In development and test neither is needed — the app falls back to a local secret
and `/dev/sign_in?email=you@example.com` mints a token the real verifier
accepts. That route is defined only under `Rails.env.development?`, and
`ClowkDevToken` raises in production.

Two surfaces stay outside the session requirement by design:

- `/up` — the image `HEALTHCHECK` curls it every 30s and has no session to offer
- `/internal/poller/*` — the Go poller authenticates with `POLLER_TOKEN` plus a
  private-IP guard

### Accounts, orgs and who sees what

An **account** is the signup tenant and groups N orgs; an **org** groups servers
and belongs to exactly one account. A **membership** is the only thing that
grants access — an account groups and bills, it never authorizes, which is what
lets someone be invited into another company's org with no exception to the
rule.

| Role | Reaches |
|---|---|
| `owner` | The account principal. People, the org itself, deleting a server. |
| `admin` | Every server in the org: PATs, alerts, dashboards, invites, grants. |
| `member` | Only the servers explicitly granted to them. No PATs, no settings. |

Alerts and saved dashboards are org-level objects that name every server in the
org, so they are admin+. Members reach the per-server surfaces: overview, pods,
logs and metrics.

Invitations are a membership row with `status: invited`. The members screen
mints a signed link the admin sends however they like — there is no SMTP in this
app. Only the person it was addressed to can accept it, and it expires in 30
days.

## Deployment shapes

One image, two shapes. Neither is a build flag — both are the same
`ghcr.io/thadeu/voodu-webui`, and the difference is two environment variables
that are **independent of each other**.

| | `CLOWK_ENABLED` | `DATABASE_URL` |
|---|---|---|
| **Self-hosted** — one box, behind your VPN | unset | unset |
| **Multi-tenant SaaS** — many people, your Postgres | `1` | `postgres://…` |
| **Enterprise** — behind your VPN, on your own Postgres | unset | `postgres://…` |

That third row is the point of keeping them independent: a company can put the
control plane on the RDS instance they already back up without also adopting a
hosted identity provider.

### What `DATABASE_URL` moves, and what it does not

Setting it moves the **primary** database to Postgres and nothing else:

| database | unset | set | holds |
|---|---|---|---|
| primary | SQLite | **Postgres** | orgs, users, accounts, memberships, servers, encrypted PATs |
| cache | SQLite | SQLite | sessions and cache — high churn, disposable |
| queue | SQLite | SQLite | pending background jobs |
| cable | SQLite | SQLite | ephemeral by nature |
| metrics | SQLite | SQLite | ~31 days of telemetry, refilled by the poller |
| hep | SQLite | SQLite | ~31 days of SIP capture, same |

You do not edit `config/database.yml` for this. Rails routes `DATABASE_URL` to
the `primary` entry natively and replaces that entry's whole configuration — the
YAML keeps declaring SQLite, and the URL overrides adapter, host and database
name on top of it.

The warehouse stays on SQLite deliberately, not for lack of trying: those two
databases are built on ground only SQLite has — generated columns computed with
`json_extract` and `strftime`, a `REGEXP` operator registered on the connection,
`COLLATE NOCASE`. Postgres could not create those tables at all.

**So the storage volume is still required with Postgres.** Losing it costs the
telemetry window (which the poller rebuilds within minutes), every session
(people sign in again) and any pending job. It does not cost an org, a user or a
PAT — those live in Postgres.

First boot needs nothing extra: the entrypoint's `rails db:prepare` creates the
Postgres database if the role may (`CREATEDB`), loads the schema into it, then
creates the five SQLite files. Pre-create the database by hand if you would
rather not grant `CREATEDB`.

### Plans

The free tier is a complete product and the default: one account, one org, one
operator, behind your own perimeter. An Enterprise licence lifts the limits.

| | Free | Enterprise |
|---|---|---|
| accounts / orgs | 1 / 1 | unlimited |
| invited members | none | unlimited |
| searchable window | 3 days | configurable, 90 by default |
| control plane in Postgres | — | ✓ |

Two ways in, and the second is the one most people will use:

```sh
VOODU_LICENSE=eyJhbGciOiJSUzI1NiJ9...      # or VOODU_LICENSE_FILE=/path/to.jwt
```

**Or paste it into Settings → Plan.** Buy a licence while already running the
free tier, paste the token, and the installation is Enterprise on the next
request — no env var, no redeploy, no restarting a dashboard someone is
watching. Renewal is the same act.

When both exist, **the newer token wins** (by its `iat`), whichever side it came
from. That is the only rule that serves an operator who only sets the env var,
one who renews through the UI, and one who keeps compose in git and updates the
env — without either side silently undoing the other.

Expiry needs no restart either: the status is read from the clock every time it
is asked. A daily job re-verifies the stored token and warns as the date
approaches, but nothing depends on it having run.

**Verified offline.** The public key ships in the image and nothing calls home,
so a licence works in a closed network and our availability is not part of your
risk. Check what the app sees with `rake 'license:inspect[<token>]'`, or in
Settings → Plan.

The token is a plain RS256 JWT — nothing voodu-specific, issuable from any
language. Format, worked example and reference implementations:
[docs/license-token-format.md](docs/license-token-format.md).

**A licence can never take anything away.** Absent, malformed and lapsed are
ordinary states that drop to the free tier — none of them stops the app. Expiry
has a 30-day grace period, after which the only changes are that new orgs and
new invitations are refused and the searchable window narrows. Specifically:

- **Nothing is deleted.** `VOODU_RETENTION_DAYS` decides how long bytes stay on
  disk and the licence never touches it. What a licence caps is how far back you
  can *search*. A lapse hides history; renewal reveals the same bytes again.
- **Postgres keeps being read.** If your control plane is in Postgres and the
  licence lapses, the app keeps serving it and says so in the UI. Locking an
  operator out of their own database is not a term we are willing to enforce.
- **Existing orgs and members stay.** Only the *next* one is refused.

That the enforcement stops there is deliberate. Anyone running the image can
modify it, so a harder technical gate would inconvenience customers without
stopping anyone — which is why the Elastic License 2.0 covers circumventing
licence-key functionality, and why the product's job here is to be honest about
the state rather than to fight its own operator.

### Backups

The two shapes have different jobs, so they get different procedures.

**SQLite (all six, or the five satellites).** Snapshot the volume, or use the
online backup so you do not copy a file mid-write:

```sh
docker exec voodu-webui sh -c \
  'for db in /rails/storage/production*.sqlite3; do
     sqlite3 "$db" ".backup /rails/storage/backup-$(basename "$db")"
   done'
```

Also in that volume, and worth more than the databases: `.secret_key_base` and
`.ar_encryption.env`. **Losing the encryption keys makes every stored PAT
unreadable** — a restored database without them is a list of servers you can no
longer talk to.

**Postgres (the primary, when `DATABASE_URL` is set).** Whatever you already do
for your other apps:

```sh
pg_dump "$DATABASE_URL" -Fc -f voodu-$(date +%F).dump
```

The two halves can drift apart in time without harm: warehouse rows for a server
that no longer exists are simply never read. Restore the primary from whenever
you like; the telemetry catches up on its own.

## Registering an server (server address)

When you add a new server in the UI you'll enter a controller URL. Pick the right one
based on where the controller lives:

| Where your `voodu` controller runs                       | Address to enter                          |
| -------------------------------------------------------- | ----------------------------------------- |
| Public server (cloud VM, bare metal with public IP)      | `https://controller.example.com`          |
| Local server on a sibling VM (Lima, OrbStack, UTM, etc.) | `http://host.docker.internal:<port>`      |
| Same Linux host as the container                         | `http://host.docker.internal:<port>`      |
| Same machine, via SSH tunnel on the host                 | `http://host.docker.internal:<tunneled>`  |

**Don't use private IPs like `192.168.x.x` from inside Docker Desktop on macOS.** The
container can NAT out through the Mac, but it can't reach the Mac's `vmnet` private
subnets (where Lima/UTM/multipass live). Channel through `host.docker.internal` and
make sure the target port is exposed to the Mac (Lima `portForwards:` in `lima.yaml`,
an OrbStack port forward, or a plain `ssh -L` tunnel).

`--network host` does **not** help on Docker Desktop — it joins the Docker VM's
network namespace, not the macOS network. Don't reach for it.

## First boot vs. restarts

- `SECRET_KEY_BASE` is auto-generated and persisted at `/rails/storage/.secret_key_base`
  when you don't ship one (and no `RAILS_MASTER_KEY` / `config/master.key`). Keep the
  storage volume to keep sessions valid.
- ActiveRecord Encryption keys (`primary_key`, `deterministic_key`, `key_derivation_salt`)
  are auto-generated and persisted at `/rails/storage/.ar_encryption.env` under the
  same condition. **Losing this file makes existing encrypted PATs unreadable** — keep
  the volume.
- First boot runs `rails db:prepare` → creates the six SQLite databases (primary,
  cache, queue, cable, metrics, hep), loads their schemas, runs `db:seed`. With
  `DATABASE_URL` set, the primary is created in Postgres instead and the other five
  are still created as files — see [Deployment shapes](#deployment-shapes).
- Subsequent boots also run `db:prepare`, which only applies pending migrations. Seeds
  do not re-run (Rails default — protects user data).

## Environment knobs

| Var                                                                                                   | Purpose                                                                                |
| ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `SECRET_KEY_BASE`                                                                                     | Override the auto-generated key.                                                       |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` / `_DETERMINISTIC_KEY` / `_KEY_DERIVATION_SALT`                | Override the auto-generated AR Encryption keys. Set all three together.                |
| `RAILS_MASTER_KEY`                                                                                    | Decrypt `config/credentials.yml.enc` if you ship encrypted credentials.                |
| `DATABASE_URL`                                                                                        | Move the **primary** database to Postgres. Unset = SQLite. Never moves the warehouse — see [Deployment shapes](#deployment-shapes). |
| `WAREHOUSE`                                                                                   | `1` enables the in-process metrics warehouse (default in the bundled compose).         |
| `HOST_HTTP_PORT` / `HOST_HTTPS_PORT`                                                                  | Compose-only — host ports forwarded to the container's `3000` / `443` (default `80` / `443`). |
| `TLS_DOMAIN`                                                                                          | Domain to get a Let's Encrypt certificate for. Empty = plain HTTP, no cert.             |
| `ACME_DIRECTORY`                                                                                      | ACME endpoint. Point at Let's Encrypt staging while testing DNS/firewall.               |
| `BASIC_AUTH_USER` / `BASIC_AUTH_PASSWORD`                                                             | Credentials for the Caddy front door (`docker-compose.auth.yml` only). Hashed at boot.  |
| `CLOWK_ENABLED`                                                                                       | `1` turns on per-person sign-in. Unset = anonymous, **unless `CLOWK_PUBLISHABLE_KEY` is set**, which keeps it on so upgrades never drop authentication. `0` forces anonymous. |
| `VOODU_TRUSTED_PERIMETER`                                                                             | `1` silences the anonymous-mode banner when an access proxy in front forwards real public client IPs. |
| `CLOWK_PUBLISHABLE_KEY`                                                                               | **Required when `CLOWK_ENABLED=1`.** Clowk instance identity — sign-in URL, JWKS endpoint and token audience derive from it. |
| `CLOWK_SECRET_KEY`                                                                                    | Optional. Clowk API calls and the legacy HS256 path; token verification does not need it. |
| `CLOWK_SUBDOMAIN_URL`                                                                                 | Optional. The instance's auth domain — set it to skip the api.clowk.dev lookup per request. |
| `HTTP_PORT`                                                                                           | Thruster's public listen port inside the container (default `3000`).                   |
| `TARGET_PORT`                                                                                         | Internal Rails port behind Thruster (default `3001`). Must differ from `HTTP_PORT`.    |
| `SOLID_QUEUE_IN_PUMA`                                                                                 | Run `solid_queue` (recurring scheduler + workers) inside the Puma process. Default `true` in the image — required for the metrics warehouse to refill every 30s. Unset to disable (e.g., when running a sidecar `bin/jobs` container). |
| `JOB_CONCURRENCY`                                                                                     | Worker processes solid_queue forks (default `1`). Bump if you have many servers.       |

## Image internals

- Rails 8.1 + Thruster (HTTP/2 in front of Puma).
- Six SQLite databases under `/rails/storage`: `production.sqlite3` (app data),
  `production_cache.sqlite3` (solid_cache), `production_queue.sqlite3` (solid_queue),
  `production_cable.sqlite3` (solid_cable), `production_metrics.sqlite3` (metrics
  warehouse) and `production_hep.sqlite3` (SIP capture). The last two carry
  high-volume background-job writes, deliberately kept off the primary.
- `rails db:prepare` runs against every configured database on boot, so all six are
  created and migrated automatically. With `DATABASE_URL` set the primary lives in
  Postgres and the remaining five are still files in the volume.
- **Background jobs run in-process.** `SOLID_QUEUE_IN_PUMA=true` (default in the image)
  loads the solid_queue Puma plugin — the dispatcher, worker pool, and recurring-task
  scheduler all run inside the same Puma process. The recurring `metrics_sync` task
  (see `config/recurring.yml`) fans out a per-server sync job every 30 seconds; if you
  unset `SOLID_QUEUE_IN_PUMA`, the metrics warehouse never refills.
- Runs as uid `1000` (`rails`). The storage volume is owned by that uid.
- Multi-arch: `linux/amd64`, `linux/arm64`.
- Healthcheck: `curl -f http://localhost:3000/up`.

## Releases & visibility

CI publishes on every push to `main` (`:latest` + `:main-<sha>`) and on `v*` tags
(`:vX.Y.Z`, `:vX.Y`, `:vX`, `:latest`).

After the first publish, make the GHCR package public (one-time):

```sh
gh api -X PATCH /user/packages/container/voodu-webui/visibility -f visibility=public
```

## Development

Standard Rails 8 setup. Ruby is pinned in `.ruby-version`, Node in `.node-version`.

```sh
bin/setup       # bundle + yarn + db:prepare
bin/dev         # Procfile.dev — Rails server + esbuild watch + css watch
bin/rails test  # tests
bin/rubocop     # lint
```

In `development` and `test`, AR Encryption keys are hardcoded in
`config/initializers/active_record_encryption.rb` so a `git clone` + `bin/dev` works
without `master.key`. Those keys are intentionally not secret.

## License

[Elastic License 2.0](LICENSE). Source-available, not OSI open source.

Self-hosting is free — run it on your own boxes, for your own servers, with no
licence to buy. Two things the licence does not permit: offering voodu-webui to
third parties as a hosted or managed service, and circumventing licence-key
functionality.

Releases published before this licence took effect remain under the terms they
shipped with.
