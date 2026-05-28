# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t voodu_webui .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name voodu_webui voodu_webui

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# ── Go build stage for the poller binary ─────────────────────
#
# Compiles `gems/poller/dist/poller` against the host's target
# arch. Isolated from the Ruby stages so the final image doesn't carry
# Go toolchain weight. The compiled binary gets COPY'd into the Rails
# build stage just before `COPY . .` resolves, so when the final stage
# pulls /rails out of the build stage it inherits the artifact at
# `gems/poller/dist/poller` for the Puma plugin + binstub.
ARG GO_VERSION=1.23
FROM docker.io/library/golang:${GO_VERSION}-alpine AS poller-build
WORKDIR /src
COPY gems/poller/src/go.mod gems/poller/src/go.sum ./
RUN go mod download
COPY gems/poller/src/ ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/poller .

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.2
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
# Thruster listens on HTTP_PORT (public) and proxies to Rails on TARGET_PORT — they must differ.
# Container's external contract: bind 3000. Rails runs internally on 3001 behind Thruster.
# Thruster overrides $PORT to $TARGET_PORT when spawning Rails, so TARGET_PORT is the knob.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    HTTP_PORT="3000" \
    TARGET_PORT="3001" \
    SOLID_QUEUE_IN_PUMA="true"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems and node modules
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libvips libyaml-dev node-gyp pkg-config python-is-python3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install JavaScript dependencies (pnpm — pinned via package.json `packageManager`).
ARG NODE_VERSION=24.13.0
ENV PATH=/usr/local/node/bin:$PATH
RUN curl -sL https://github.com/nodenv/node-build/archive/master.tar.gz | tar xz -C /tmp/ && \
    /tmp/node-build-master/bin/node-build "${NODE_VERSION}" /usr/local/node && \
    corepack enable && \
    rm -rf /tmp/node-build-master

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock .ruby-version ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Install node modules
COPY package.json pnpm-lock.yaml ./
RUN corepack prepare --activate && pnpm install --frozen-lockfile

# Copy application code
COPY . .

# Drop the prebuilt poller binary in place. The Puma plugin
# (lib/puma/plugin/poller.rb) + binstub (bin/poller) both
# resolve the executable via Poller.binary_path, which expects
# `gems/poller/dist/poller` to exist when POLLER_SPAWN=1.
COPY --from=poller-build /out/poller ./gems/poller/dist/poller

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile


RUN rm -rf node_modules


# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# OCI image labels — links package to repo on GHCR + marks license.
LABEL org.opencontainers.image.source="https://github.com/thadeu/voodu-webui" \
      org.opencontainers.image.description="Voodu Web UI — zero-config Rails 8 dashboard for the voodu PaaS." \
      org.opencontainers.image.licenses="MIT"

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Container listens on 3000 internally; map any host port to 3000 at `docker run`.
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://localhost:3000/up || exit 1

# Start server via Thruster by default, this can be overwritten at runtime
CMD ["./bin/thrust", "./bin/rails", "server"]
