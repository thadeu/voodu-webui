# poller

Go-based log NDJSON poller for voodu servers. Mirrors the `solid_queue` gem
pattern: ships a binary, plugs into Puma, and writes durable per-pod NDJSON
files under `storage/logs/<server>/<pod>/YYYY-MM-DD.ndjson`.

## What it does

For every server registered in the Rails app, the binary opens a long-lived
goroutine that:

1. Takes an exclusive file lock on `storage/logs/<server>/.writer.lock` so
   only one process can write a given server's tree at once.
2. Reads a watermark sidecar (`.watermark` per pod) that records the
   timestamp of the last persisted line.
3. Polls `GET /api/pat/v1/logs?follow=false&tail=500&since=<watermark>&timestamps=true`
   on the server's voodu controller using its PAT.
4. Parses each `[pod] <ts> <body>` line, dedups via an xxhash64 sliding
   ring (5000 entries / pod), appends to today's NDJSON file, and bumps
   the watermark via atomic rename.

A `/healthz` and `/metrics` endpoint runs on `:9999` for liveness probes.

## Environment

Both the Ruby shim and the Go binary check `POLLER_SPAWN`. If it is not
exactly `"1"`, they exit 0 immediately so Puma will not restart-storm.

| Env var                          | Default                     | Notes                              |
| -------------------------------- | --------------------------- | ---------------------------------- |
| `POLLER_SPAWN`                 | unset (disabled)            | Set to `1` to enable               |
| `POLLER_TOKEN`      | required                    | Auth to Rails internal endpoint    |
| `RAILS_INTERNAL_URL`             | `http://127.0.0.1:3000`     | Rails app base URL                 |
| `POLLER_INTERVAL_SECONDS`    | `15` (min `5`)              | Per-server poll cadence            |
| `POLLER_STORAGE_DIR`         | `./storage/logs`            | NDJSON output root                 |
| `POLLER_OBSERVABILITY_ADDR`  | `:9999`                     | Bind for `/healthz` + `/metrics`   |
| `POLLER_VERBOSE`             | unset (silent)              | Set to `1` to log one summary line per server per tick (pods/scanned/written/deduped/elapsed/wm_lag) |

## Building the binary

```sh
cd gems/poller && make build
```

Produces `gems/poller/src/poller`. The Puma plugin and the Ruby
binstub both resolve to that path via `Poller.binary_path`.

## Running standalone

The Rails binstub (installed by the Railtie on first boot) execs the
compiled binary, inheriting env from the parent shell:

```sh
POLLER_SPAWN=1 POLLER_TOKEN=... bin/poller
```

## Production / Docker

The repo's `Dockerfile` builds the binary in a dedicated multi-stage
`poller-build` stage (alpine + Go toolchain, isolated from the
Ruby image) and `COPY --from=poller-build` lands the artifact at
`gems/poller/src/poller` in the final image. No Go toolchain
ships in the runtime image. The binary inherits the container's env
vars, so set `POLLER_TOKEN` via kamal secrets / docker
`-e` / systemd `Environment=` / .env — same place you set
`RAILS_MASTER_KEY`.

## Running under Puma

`config/puma.rb` activates the plugin:

```ruby
plugin :poller
```

If `POLLER_SPAWN=1`, the plugin spawns the binary on `on_booted`, sends
`SIGTERM` on `on_stopped`, and waits for the process to drain.
