# voodu-webui — dev stack.
#   make up            everything: rails (:3000) + esbuild + tailwind + jobs
#   make up-with-logs  same thing (this stack is always in the foreground)
#   make test          the whole suite
#
# `up` here is the Procfile stack, NOT docker compose. The compose file in this
# repo runs the RELEASED image (ghcr.io/thadeu/voodu-webui) the way an operator
# would — it is not a dev environment, and building against it would give you a
# container with no live reload and yesterday's assets. The docker-* targets
# below are for exercising that release path on purpose.

DEV ?= bin/dev
COMPOSE ?= docker compose
ENV_FILE ?= .env
PORT ?= 3000

.PHONY: up up-with-logs setup deps db down stop restart console routes \
        test lint fix db-reset docker-up docker-logs docker-down docker-build help

help:
	@echo "run:    up up-with-logs setup console routes"
	@echo "db:     db db-reset"
	@echo "check:  test lint fix"
	@echo "docker: docker-up docker-logs docker-down docker-build"

# dotenv-rails loads this in development and test. Copied from the template on
# first run so a fresh clone has one; every value in it is optional (sign-in
# falls back to /dev/sign_in when no Clowk key is configured).
$(ENV_FILE):
	@echo "-----> writing $(ENV_FILE) from .env.example"
	@cp .env.example $(ENV_FILE)

deps:
	@echo "-----> gems"
	@bundle check >/dev/null 2>&1 || bundle install
	@echo "-----> js (pnpm — never npm/yarn, the lockfile is pnpm's)"
	@pnpm install --frozen-lockfile

# All five databases: primary, cache, queue, cable and the metrics warehouse
# (plus hep). db:prepare is idempotent — first run creates and loads, later
# runs only apply pending migrations.
db:
	@echo "-----> databases"
	@bin/rails db:prepare

setup: $(ENV_FILE) deps db
	@echo "-----> ready. \`make up\`"

# Foreground on purpose: foreman interleaves all four processes' logs, which is
# what you want while developing. Nothing to detach from, nothing to tail.
up: setup
	@echo "-----> rails    http://localhost:$(PORT)"
	@echo "-----> sign in  http://localhost:$(PORT)/login"
	@PORT=$(PORT) $(DEV)

# Kept for muscle memory across projects. This stack has no detached mode, so
# `up` already shows every log line.
up-with-logs: up

# Through THIS checkout's pidfile, never `pkill -f foreman`: that pattern
# matches any foreman running any Procfile.dev on the machine — a second
# checkout, a colleague's app, your own instance on another port — and kills it
# without asking. Killing web is enough anyway: foreman tears the rest down
# when any process exits.
down stop:
	@echo "-----> stopping"
	@if [ -f tmp/pids/server.pid ]; then \
		kill $$(cat tmp/pids/server.pid) 2>/dev/null || true; \
		echo "-----> stopped (pid $$(cat tmp/pids/server.pid))"; \
	else \
		echo "-----> nothing running from this checkout"; \
	fi

restart: down up

console:
	@bin/rails console

routes:
	@bin/rails routes

test:
	@echo "-----> minitest"
	@bin/rails test

lint:
	@echo "-----> rubocop"
	@bin/rubocop
	@echo "-----> eslint"
	@pnpm run lint
	@echo "-----> brakeman"
	@bin/brakeman --no-pager

fix:
	@bin/rubocop -a
	@pnpm run lint:fix

# Drops and recreates every database. The dev data here is registered servers
# and their encrypted PATs — losing it means re-registering them, so this is
# never part of `setup`.
db-reset:
	@echo "-----> dropping and recreating every database"
	@bin/rails db:drop db:create db:migrate

# ── The release path ─────────────────────────────────────────────────────
# Runs the published image the way an operator does, to check the container
# itself: entrypoint, healthcheck, the Go poller, TLS. Needs CLOWK_PUBLISHABLE_KEY
# in .env — sign-in is mandatory and the app refuses to boot without it.

docker-up: $(ENV_FILE)
	@echo "-----> released image"
	@$(COMPOSE) up -d --remove-orphans
	@$(COMPOSE) ps

docker-logs:
	@$(COMPOSE) logs -f

docker-down:
	@$(COMPOSE) down

docker-build:
	@$(COMPOSE) build
