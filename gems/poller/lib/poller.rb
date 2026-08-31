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

  # Resolves the path the Puma plugin / Runner should exec.
  #
  # Preference order:
  #   1. `gems/poller/dist/poller`    — compiled Go binary
  #   2. `gems/poller/exe/poller`     — shell wrapper (env-gated noop)
  #
  # The shell wrapper exists so a fresh checkout (no `make build` yet)
  # still has a callable executable — it just exits 0 immediately.
  #
  # `dist/` (not `src/`) because `src/poller/` is the Go package dir;
  # `bin/` (not `bin/poller`) because that holds the Ruby binstub
  # template the Railtie installs into the Rails app.
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

  def self.binary_path
    compiled = File.join(GEM_ROOT, "dist", "poller")

    return compiled if File.executable?(compiled)

    File.join(GEM_ROOT, "exe", "poller")
  end
end

require "poller/railtie" if defined?(Rails::Railtie)
