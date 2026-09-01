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
# Always on. The poller is the only thing that fills the warehouse, so a
# Puma without it is a dashboard with nothing in it — and the Railtie has
# already refused to boot if the binary is missing, so by the time this
# runs there is something to spawn.
#
# The binary POSTs its digests back to Rails at `RAILS_INTERNAL_URL`,
# which defaults (in the Go binary) to a hardcoded `:3000`. We spawn
# inside the same Puma that just bound `PORT`, so we're the one process
# that knows the real port — derive the callback URL from it. Without
# this, `PORT=4002 bin/dev` boots Puma on 4002 while the poller keeps
# hammering :3000, every digest POST is refused, and the warehouse
# silently stops refilling — there is no fallback. An explicit
# `RAILS_INTERNAL_URL` still wins, for a reverse proxy / non-loopback deploy.
Puma::Plugin.create do
  def start(launcher)
    launcher.events.on_booted do
      binary = Poller.binary_path
      rails_url = ENV["RAILS_INTERNAL_URL"] || "http://127.0.0.1:#{ENV.fetch("PORT", 3000)}"
      # The binary sweeps its own NDJSON tree, so it needs the same keep window
      # Rails honours. A plain number, deliberately: enforcement stays in Ruby
      # and the Go side never learns that licences exist.
      env = {"RAILS_INTERNAL_URL" => rails_url, "POLLER_RETENTION_DAYS" => Retention.keep_days.to_s}

      if Poller.stale_binary?
        launcher.log_writer.log(
          "[poller] WARNING: dist/poller is older than gems/poller/src — run " \
          "`make -C gems/poller build`. Until then this runs the previous " \
          "build, and a protocol change surfaces as a flat 401."
        )
      end

      @pid = spawn(env, binary, out: $stdout, err: $stderr)

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
