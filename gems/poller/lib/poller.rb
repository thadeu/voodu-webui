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
  def self.binary_path
    compiled = File.join(GEM_ROOT, "dist", "poller")

    return compiled if File.executable?(compiled)

    File.join(GEM_ROOT, "exe", "poller")
  end
end

require "poller/railtie" if defined?(Rails::Railtie)
