# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...

## Docker

The image ships Rails 8.1 + Thruster, the Solid stack (`solid_cache`, `solid_queue`, `solid_cable`) on SQLite, runs as uid `1000` (`rails`), and exposes **3000** internally. Map any external host port — `-p <host>:3000` — at run time.

**First boot vs. restarts.**

- `SECRET_KEY_BASE` is auto-generated and persisted at `/rails/storage/.secret_key_base` when you don't ship one (and no `RAILS_MASTER_KEY` / `config/master.key`). Keep the storage volume to keep sessions valid.
- First boot runs `rails db:prepare` → creates SQLite DBs, loads the schema, runs `db:seed`.
- Subsequent boots also run `db:prepare`, which only applies pending migrations. Seeds do not re-run (Rails design — protects user data).

**Environment knobs.**

| Var | Purpose |
| --- | --- |
| `SECRET_KEY_BASE` | Override the auto-generated key. |
| `RAILS_MASTER_KEY` | Decrypt `config/credentials.yml.enc` if you ship encrypted credentials. |
| `DATABASE_URL` | Swap SQLite for Postgres later without rebuilding. |
| `HOST_PORT` | Compose-only — external port forwarded to internal 3000 (default `3000`). |
| `HTTP_PORT` | Thruster's public listen port inside the container (default `3000`). |
| `TARGET_PORT` | Internal Rails port behind Thruster (default `3001`). Must differ from `HTTP_PORT`. |

**Make the GHCR package public** (one-time, after first publish):

```sh
gh api -X PATCH /user/packages/container/voodu-webui/visibility -f visibility=public
```

CI publishes on every push to `main` (`:latest` + `:main-<sha>`) and on `v*` tags (`:vX.Y.Z`, `:vX.Y`, `:vX`, `:latest`).

## Pull & Run (end users)

### Without docker-compose

```sh
# 1. Pull the image
docker pull ghcr.io/thadeu/voodu-webui:latest

# 2. Run on the default port (3000)
docker run -d --name voodu-webui \
  -p 3000:3000 \
  -v voodu_webui_storage:/rails/storage \
  --restart unless-stopped \
  ghcr.io/thadeu/voodu-webui:latest

# Custom external port — internal is always 3000
docker run -d -p 80:3000    -v voodu_webui_storage:/rails/storage ghcr.io/thadeu/voodu-webui:latest
docker run -d -p 1886:3000  -v voodu_webui_storage:/rails/storage ghcr.io/thadeu/voodu-webui:latest
docker run -d -p 18687:3000 -v voodu_webui_storage:/rails/storage ghcr.io/thadeu/voodu-webui:latest

# View logs / stop / restart
docker logs -f voodu-webui
docker stop voodu-webui && docker start voodu-webui
```

### With docker-compose

```sh
# 1. Grab the compose file + env template
curl -O https://raw.githubusercontent.com/thadeu/voodu-webui/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/thadeu/voodu-webui/main/.env.example
mv .env.example .env

# 2. (Optional) edit .env to change the host port
#    HOST_PORT=1886

# 3. Start
docker compose up -d

# Logs / stop / upgrade
docker compose logs -f
docker compose pull && docker compose up -d   # upgrade to a newer image
docker compose down
```
