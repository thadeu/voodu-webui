# frozen_string_literal: true

# LogTail::Feature — kill switch for the entire warehouse subsystem.
#
# `LOG_TAIL_ENABLED=1` (default) → orchestrator + island jobs run as
# usual. `LOG_TAIL_ENABLED=0` → orchestrator early-returns, in-flight
# jobs honor the flag on their next reconnect cycle.
#
# Single env var because that's the granularity the operator decision
# settled on for the POC: turn the whole feature off without code
# changes when disk pressure spikes or we need to debug something.
# Per-island toggles live in a UI follow-up if useful.
module LogTail
  module Feature
    module_function

    # enabled? — true unless explicitly opted out. Default `"1"`
    # because most environments will want logs persisted.
    def enabled?
      ENV.fetch("LOG_TAIL_ENABLED", "1") == "1"
    end
  end
end
