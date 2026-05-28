# frozen_string_literal: true

require "log_poller"

module LogPoller
  # Runner — entrypoint used by the Rails app's `bin/log-poller` binstub.
  #
  # Responsibilities:
  #   - Default `RAILS_INTERNAL_URL` to localhost:3000 when not set.
  #   - exec(3) the binary so the binstub process is replaced — no Ruby
  #     residue in `ps`, no stale signal handlers.
  #
  # Configuration comes from environment variables only — no Rails
  # credentials lookup. The Go child reads `LOG_POLLER_TOKEN`
  # from its own env (same way the operator sets RAILS_ENV /
  # DATABASE_URL / kamal secrets / docker -e). Lookup chain in the
  # binary itself: ENV → fail-fast.
  module Runner
    module_function

    def start
      ENV["RAILS_INTERNAL_URL"] ||= "http://127.0.0.1:3000"
      exec(LogPoller.binary_path)
    end
  end
end
