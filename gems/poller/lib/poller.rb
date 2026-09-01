# frozen_string_literal: true

require "poller/version"

# Poller — Ruby surface for the Go log poller binary.
#
# The actual work is done by a Go binary shipped under
# `gems/poller/src/`. This module gives the Ruby side three things:
#
#   1. A version constant.
#   2. `binary_path` — resolves the absolute path of the compiled binary,
#      with a graceful fallback to the shell wrapper under `exe/`.
#   3. Autoloads for `Runner` (used by the Rails binstub) and the
#      `Railtie` (which installs the binstub on `bundle install`).
#
# The Puma plugin lives at `lib/puma/plugin/poller.rb` so Puma can
# discover it via its standard `plugin :poller` convention.
module Poller
  autoload :Runner, "poller/runner"
  autoload :Railtie, "poller/railtie"

  GEM_ROOT = File.expand_path("..", __dir__)

  # Where the compiled binary lives: `dist/`, not `src/` (that is the Go
  # package dir) and not `bin/` (that holds the Ruby binstub template the
  # Railtie installs into the Rails app).
  BINARY = File.join(GEM_ROOT, "dist", "poller")

  class BinaryMissing < StandardError; end

  # stale_binary? — is the compiled binary older than the Go source it came from?
  #
  # `dist/poller` is gitignored and built by hand (`make build`), so editing the
  # Go side and restarting only reruns the OLD binary. That cost a debugging
  # session once: the signing change landed in source, the four-day-old binary
  # kept sending `Authorization: Bearer`, and the controller answered every
  # request with a flat 401 "invalid or expired token" — which reads as a
  # credential problem and is a build problem.
  #
  # Nil when there is nothing to compare (no compiled binary, or no source tree
  # — the shipped image has one and not the other, and must stay quiet).
  def self.stale_binary?
    compiled = File.join(GEM_ROOT, "dist", "poller")
    return nil unless File.executable?(compiled)

    # _test.go is excluded: it never reaches the binary, so counting it would
    # cry stale every time somebody edited a test.
    sources = Dir.glob(File.join(GEM_ROOT, "src", "**", "*.go")).grep_v(/_test\.go\z/)
    newest = sources.max_by { |f| File.mtime(f) }
    return nil if newest.nil?

    File.mtime(newest) > File.mtime(compiled)
  end

  # The executable the Puma plugin and the Runner exec. Only ever the compiled
  # binary: there used to be a shell wrapper underneath it that exited 0 when
  # nothing was built, so a fresh checkout booted, "ran" the poller, and synced
  # nothing — no pods, no metrics, no logs, and no error anywhere. A path that
  # points at nothing is what require_binary! exists to catch, before that.
  def self.binary_path = BINARY

  def self.binary? = File.executable?(BINARY)

  # Refuse to go on without the binary. Called by the Railtie on every boot and
  # by the Runner before exec, so the failure is one sentence with the fix in
  # it rather than a dashboard that stays empty.
  #
  # The binary is built by `make -C gems/poller build` (needs a Go toolchain)
  # and shipped ready-made in the Docker image, where the poller-build stage
  # produces it. Missing therefore means one of two things, and the message
  # names both. Bundler cannot do this for us: it installs path gems with
  # extensions disabled, so there is no install-time hook to lean on.
  def self.require_binary!
    return if binary?

    raise BinaryMissing, <<~MSG.strip
      poller binary not found at #{BINARY}

      The poller is the only thing that fills this app's warehouse, so it
      will not start without it. Build it once (needs Go — https://go.dev/dl):

        make -C gems/poller build

      In the Docker image it is copied in from the poller-build stage; if you
      are seeing this there, that stage did not run.
    MSG
  end
end

require "poller/railtie" if defined?(Rails::Railtie)
