# frozen_string_literal: true

require "log_poller/version"

# LogPoller — Ruby surface for the Go log poller binary.
#
# The actual work is done by a Go binary shipped under
# `gems/log_poller/src/`. This module gives the Ruby side three things:
#
#   1. A version constant.
#   2. `binary_path` — resolves the absolute path of the compiled binary,
#      with a graceful fallback to the shell wrapper under `exe/`.
#   3. Autoloads for `Runner` (used by the Rails binstub) and the
#      `Railtie` (which installs the binstub on `bundle install`).
#
# The Puma plugin lives at `lib/puma/plugin/log_poller.rb` so Puma can
# discover it via its standard `plugin :log_poller` convention.
module LogPoller
  autoload :Runner,  "log_poller/runner"
  autoload :Railtie, "log_poller/railtie"

  GEM_ROOT = File.expand_path("..", __dir__)

  # Resolves the path the Puma plugin / Runner should exec.
  #
  # Preference order:
  #   1. `gems/log_poller/src/log-poller`     — compiled Go binary
  #   2. `gems/log_poller/exe/log-poller`     — shell wrapper (env-gated noop)
  #
  # The shell wrapper exists so a fresh checkout (no `make build` yet)
  # still has a callable executable — it just exits 0 immediately.
  def self.binary_path
    compiled = File.join(GEM_ROOT, "src", "log-poller")

    return compiled if File.executable?(compiled)

    File.join(GEM_ROOT, "exe", "log-poller")
  end
end

require "log_poller/railtie" if defined?(Rails::Railtie)
