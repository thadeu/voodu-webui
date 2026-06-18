# frozen_string_literal: true

# LogTail::Parser — turns a raw log line into a structured hash for
# persistence. Tolerant: JSON line is parsed when possible, plain
# text falls through with `parsed: false`. Either way, the original
# raw string is preserved under `raw` so an export can reconstruct
# the exact line the operator saw on /logs.
#
# Expected wire shape (from controller's multi-pod /logs fan-out):
#
#   "<pod_name> | <raw line>\n"
#
# The leading "pod_name | " prefix is added by the controller when
# fan-out includes multiple pods. We strip it here so the persisted
# row's `raw` field is the original log line (clean), with `pod`
# captured separately.
#
# For single-pod streams (no prefix), we accept the line as-is and
# the caller supplies the pod name out-of-band.
module LogTail
  module Parser
    module_function

    # Controller's multi-pod log fan-out prefixes each line as
    # "[pod-name] <message>" — see handleLogsMulti in
    # clowk-voodu/internal/controller/handlers_logs_multi.go:240
    #   prefix := []byte("[" + p.Name + "] ")
    #
    # Regex captures everything between the first `[` and the matching
    # `]` (greedy until close bracket), then a single space, then the
    # rest. Anchored at the START so a stray "[stream error]" later in
    # the body (controller writes "[pod] [stream error] msg" on
    # per-pod open failures) stays verbatim in the body.
    PREFIX_RE = /\A\[([^\]]+)\]\s(.*)\z/

    # parse — turns one raw chunk-line into a persistable hash.
    #
    # @param raw_line [String]   one line of the stream (no \n)
    # @param pod_hint [String]   pod name if known out-of-band
    #                            (single-pod streams). nil for
    #                            multi-pod where the prefix carries it.
    # @return [Hash]             { ts:, pod:, stream:, level:, msg:,
    #                              raw:, parsed: }
    def parse(raw_line, pod_hint: nil)
      stripped = raw_line.to_s.chomp

      pod, body = split_prefix(stripped, pod_hint)
      parsed = try_json(body)

      {
        ts: parsed.fetch(:ts, Time.current.iso8601(3)),
        pod: pod.presence || "unknown",
        stream: parsed.fetch(:stream, "stdout"),
        level: parsed.fetch(:level, nil),
        msg: parsed.fetch(:msg, body),
        raw: stripped,
        parsed: parsed[:parsed] == true
      }
    end

    # split_prefix — extracts the "[pod-name] " prefix the controller
    # emits in multi-pod fan-out streams.
    #
    #   "[newcall-api.e41c] {\"level\":\"INFO\",...}" → ["newcall-api.e41c", "{...}"]
    #   "[newcall-api.e41c] plain text line"          → ["newcall-api.e41c", "plain text line"]
    #   "[newcall-api.e41c] [stream error] EOF"       → ["newcall-api.e41c", "[stream error] EOF"]
    #
    # When no prefix matches (single-pod stream from /pods/:name/logs,
    # raw docker log), fall back to (pod_hint, full_line).
    def split_prefix(line, pod_hint)
      m = PREFIX_RE.match(line)
      return [pod_hint, line] unless m

      [m[1], m[2]]
    end

    # try_json — best-effort structured field extraction. Returns
    # a hash with `:parsed => true` on success, mostly-empty on
    # failure. Common log shapes: slog (`time`, `level`, `msg`),
    # zerolog (same), bunyan (`time`, `level` numeric, `msg`).
    def try_json(body)
      stripped = body.to_s.strip
      return {parsed: false} unless stripped.start_with?("{")

      doc = JSON.parse(stripped)
      return {parsed: false} unless doc.is_a?(Hash)

      {
        parsed: true,
        ts: normalize_ts(doc["time"] || doc["ts"] || doc["timestamp"]),
        level: normalize_level(doc["level"] || doc["lvl"] || doc["severity"]),
        msg: (doc["msg"] || doc["message"] || stripped).to_s,
        stream: doc["stream"]
      }.compact
    rescue JSON::ParserError, EncodingError, ArgumentError
      {parsed: false}
    end

    # normalize_ts — accept ISO8601 strings or numeric seconds/ms
    # since epoch. Return ISO8601(3) string for storage uniformity.
    def normalize_ts(raw)
      return nil if raw.nil?

      case raw
      when Numeric
        # Heuristic: > 1e12 means milliseconds; else seconds.
        seconds = (raw > 1e12) ? raw / 1000.0 : raw.to_f
        Time.zone.at(seconds).iso8601(3)
      else
        # Round-trip through Time.zone.parse to normalise format.
        Time.zone.parse(raw.to_s)&.iso8601(3)
      end
    rescue ArgumentError, TypeError
      nil
    end

    # normalize_level — uppercase string. Accepts strings ("info",
    # "INFO", "warn") and numeric (bunyan: 10=trace, 20=debug,
    # 30=info, 40=warn, 50=error, 60=fatal).
    BUNYAN_LEVELS = {
      10 => "TRACE", 20 => "DEBUG", 30 => "INFO",
      40 => "WARN", 50 => "ERROR", 60 => "FATAL"
    }.freeze

    def normalize_level(raw)
      return nil if raw.nil?

      case raw
      when Numeric then BUNYAN_LEVELS[raw.to_i] || "INFO"
      when String then raw.upcase
      end
    end
  end
end
