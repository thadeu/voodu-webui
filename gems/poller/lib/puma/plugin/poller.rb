# frozen_string_literal: true

require "puma/plugin"
require "poller"

# Puma::Plugin :poller —
#
# Wires the compiled Go binary into Puma's process lifecycle:
#
#   - on_booted   → spawn the binary, log its PID
#   - on_stopped  → SIGTERM the binary, wait for it to drain
#
# Gated by `POLLER_SPAWN=1`. When unset, the plugin is a noop so the
# default Puma boot stays silent for everyone who is not running this
# subsystem.
#
# The binary POSTs its digests back to Rails at `RAILS_INTERNAL_URL`,
# which defaults (in the Go binary) to a hardcoded `:3000`. We spawn
# inside the same Puma that just bound `PORT`, so we're the one process
# that knows the real port — derive the callback URL from it. Without
# this, `PORT=4002 bin/dev` boots Puma on 4002 while the poller keeps
# hammering :3000, every digest POST is refused, and the warehouse
# silently stops refilling (the Ruby sync jobs are no-ops under
# POLLER_SPAWN, so there's no fallback). An explicit `RAILS_INTERNAL_URL`
# still wins — for a reverse proxy / non-loopback deploy.
Puma::Plugin.create do
  def start(launcher)
    return unless ENV["POLLER_SPAWN"] == "1"

    launcher.events.on_booted do
      binary = Poller.binary_path
      rails_url = ENV["RAILS_INTERNAL_URL"] || "http://127.0.0.1:#{ENV.fetch("PORT", 3000)}"
      @pid = spawn({"RAILS_INTERNAL_URL" => rails_url}, binary, out: $stdout, err: $stderr)

      launcher.log_writer.log("[poller] spawned PID #{@pid} → #{rails_url}")
    end

    launcher.events.on_stopped do
      next unless @pid

      Process.kill("TERM", @pid)
      Process.wait(@pid)
      launcher.log_writer.log("[poller] drained PID #{@pid}")
    rescue Errno::ESRCH, Errno::ECHILD
      # already gone — nothing to drain
    end
  end
end
