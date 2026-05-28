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
Puma::Plugin.create do
  def start(launcher)
    return unless ENV["POLLER_SPAWN"] == "1"

    launcher.events.on_booted do
      binary = Poller.binary_path
      @pid   = spawn(binary, out: $stdout, err: $stderr)

      launcher.log_writer.log("[poller] spawned PID #{@pid}")
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
