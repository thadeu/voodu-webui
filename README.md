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
  talk to its `voodu` controller; tokens live in SQLite as `pat_ciphertext` and are
  encrypted via ActiveRecord Encryption.
- **Single container.** Rails 8.1 on SQLite with the Solid stack (`solid_cache`,
  `solid_queue`, `solid_cable`) — no Postgres, no Redis, no sidekiq, no separate worker
  pod. Add a volume, you're done.

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
- First boot runs `rails db:prepare` → creates the four SQLite DBs (main + cache +
  queue + cable), loads the schema, runs `db:seed`.
- Subsequent boots also run `db:prepare`, which only applies pending migrations. Seeds
  do not re-run (Rails default — protects user data).

## Environment knobs

| Var                                                                                                   | Purpose                                                                                |
| ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `SECRET_KEY_BASE`                                                                                     | Override the auto-generated key.                                                       |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` / `_DETERMINISTIC_KEY` / `_KEY_DERIVATION_SALT`                | Override the auto-generated AR Encryption keys. Set all three together.                |
| `RAILS_MASTER_KEY`                                                                                    | Decrypt `config/credentials.yml.enc` if you ship encrypted credentials.                |
| `DATABASE_URL`                                                                                        | Swap SQLite for Postgres later without rebuilding.                                     |
| `WAREHOUSE`                                                                                   | `1` enables the in-process metrics warehouse (default in the bundled compose).         |
| `HOST_HTTP_PORT` / `HOST_HTTPS_PORT`                                                                  | Compose-only — host ports forwarded to the container's `3000` / `443` (default `80` / `443`). |
| `TLS_DOMAIN`                                                                                          | Domain to get a Let's Encrypt certificate for. Empty = plain HTTP, no cert.             |
| `ACME_DIRECTORY`                                                                                      | ACME endpoint. Point at Let's Encrypt staging while testing DNS/firewall.               |
| `BASIC_AUTH_USER` / `BASIC_AUTH_PASSWORD`                                                             | Credentials for the Caddy front door (`docker-compose.auth.yml` only). Hashed at boot.  |
| `HTTP_PORT`                                                                                           | Thruster's public listen port inside the container (default `3000`).                   |
| `TARGET_PORT`                                                                                         | Internal Rails port behind Thruster (default `3001`). Must differ from `HTTP_PORT`.    |
| `SOLID_QUEUE_IN_PUMA`                                                                                 | Run `solid_queue` (recurring scheduler + workers) inside the Puma process. Default `true` in the image — required for the metrics warehouse to refill every 30s. Unset to disable (e.g., when running a sidecar `bin/jobs` container). |
| `JOB_CONCURRENCY`                                                                                     | Worker processes solid_queue forks (default `1`). Bump if you have many servers.       |

## Image internals

- Rails 8.1 + Thruster (HTTP/2 in front of Puma).
- Five SQLite databases under `/rails/storage`: `production.sqlite3` (app data),
  `production_cache.sqlite3` (solid_cache), `production_queue.sqlite3` (solid_queue),
  `production_cable.sqlite3` (solid_cable), `production_metrics.sqlite3` (metrics
  warehouse — high-volume background-job writes kept off the primary).
- `rails db:prepare` runs against every configured database on boot, so all five files
  are created and migrated automatically.
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
