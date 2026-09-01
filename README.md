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

### With voodu itself

The dashboard can be deployed by the controller it manages — rollouts, health
gating and TLS at the ingress, instead of a `docker run` you have to remember.

→ [docs/deploy-with-voodu.md](docs/deploy-with-voodu.md) — a complete
`web.voodu` manifest with ports, volume, probes and TLS.

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

Automatic, once a name points here and ports 80 and 443 are open:

```sh
TLS_DOMAIN=console.example.com
```

Thruster requests a Let's Encrypt certificate, redirects HTTP to HTTPS and
renews it. Empty means plain HTTP, which is right when something in front
already terminates TLS.

→ [docs/tls.md](docs/tls.md) — the three conditions, the port mapping that looks
like a TLS bug, Cloudflare, and what each failure actually means.

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

### How the dashboard authenticates to a controller

Signed requests, not a bearer token: the PAT never travels, so an intercepted
request is one request rather than a credential.

→ [docs/pat-authorization.md](docs/pat-authorization.md) — the scheme, how to
sign one by hand, and what it does and does not protect.

### Operator sign-in

**Off by default on a fresh install.** The app asks for no credentials and the
perimeter — Twingate, a VPN, an access proxy — is the door. Whoever reaches the
port is an operator, and an operator can read every server's access token, so
do not publish it without one in front.

For per-person identity, `CLOWK_ENABLED=1` with a publishable key, or configure
it at `/ops/sso` while already running. **Upgrades never remove sign-in**: a
configured `CLOWK_PUBLISHABLE_KEY` keeps it on even without the flag.

→ [docs/sso.md](docs/sso.md) — turning it on, the workspace handover, and how to
get back out.

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

One image, two independent switches. Neither is a build flag.

| | `CLOWK_ENABLED` | `DATABASE_URL` |
|---|---|---|
| **Self-hosted** — one box, behind your VPN | unset | unset |
| **Multi-tenant SaaS** — many people, your Postgres | `1` | `postgres://…` |
| **Enterprise** — behind your VPN, on your own Postgres | unset | `postgres://…` |

That third row is why they are independent: a company can put the control plane
on the RDS they already back up without also adopting a hosted identity
provider.

- → [docs/self-hosted.md](docs/self-hosted.md) — `docker run`, the perimeter,
  the volume, backups
- → [docs/enterprise.md](docs/enterprise.md) — what a licence lifts, activating
  it, what a lapse can and cannot do
- → [docs/sso.md](docs/sso.md) — per-person identity and the workspace handover
- → [docs/database.md](docs/database.md) — what `DATABASE_URL` moves, retention,
  and why switching is a fresh start

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
