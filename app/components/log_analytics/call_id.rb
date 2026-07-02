# frozen_string_literal: true

# Components::LogAnalytics::CallId — the one place that knows how to pull a
# SIP Call-ID out of a raw log line. FreeSWITCH (and the SIP stack in
# general) prints `Call-ID: <id>` inline; the value runs up to the next
# whitespace / `;` / `,`. Shared by the per-row bridge chip (Row) and the
# Surrounding modal's call-flow button so the two never drift on what counts
# as a Call-ID.
module Components::LogAnalytics::CallId
  PATTERN = /call-id:\s*([^\s;,]+)/i

  # sip_call_id_from — the Call-ID in `raw`, or nil. Never raises on a nil /
  # non-string line (a malformed record just yields no chip).
  def sip_call_id_from(raw)
    raw.to_s[PATTERN, 1]
  end
end
