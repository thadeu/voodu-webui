# frozen_string_literal: true

require "test_helper"

# Pins LogTail::Parser — the ingestion step that turns one raw stream line
# into the persisted { ts, pod, stream, level, msg, raw, parsed } hash. The
# scenarios that matter: the "[pod] " fan-out prefix is peeled, JSON lines
# get their fields lifted, and — the reason this file exists — ANSI colour
# escapes a TTY app (FreeSWITCH's SIP trace) prints are scrubbed at ingestion
# so the warehouse never stores `[32m`/`[m` litter.
class LogTail::ParserTest < ActiveSupport::TestCase
  ESC = "\e"

  test "peels the multi-pod [pod] prefix into pod + body" do
    row = LogTail::Parser.parse("[newcall-api.e41c] plain text line")

    assert_equal "newcall-api.e41c", row[:pod]
    assert_equal "plain text line", row[:msg]
    # `raw` keeps the whole line (prefix included) — pre-existing behaviour;
    # only `msg`/`body` are prefix-stripped.
    assert_equal "[newcall-api.e41c] plain text line", row[:raw]
    refute row[:parsed]
  end

  test "falls back to the pod hint when there is no prefix" do
    row = LogTail::Parser.parse("just a line", pod_hint: "fsw-freeswitch.0")

    assert_equal "fsw-freeswitch.0", row[:pod]
    assert_equal "just a line", row[:msg]
  end

  test "lifts ts/level/msg from a JSON line" do
    row = LogTail::Parser.parse(%([api.0] {"level":"info","msg":"started","time":"2026-07-02T10:00:00Z"}))

    assert row[:parsed]
    assert_equal "api.0", row[:pod]
    assert_equal "INFO", row[:level]
    assert_equal "started", row[:msg]
  end

  # The bug this file was created for: FreeSWITCH prints its SIP trace with
  # SGR colour escapes (`\e[m`, `\e[32m`). The invisible ESC renders to
  # nothing in a browser, leaving the CSI tail as visible litter. Scrub it at
  # ingestion so `raw` AND `msg` are clean — everything downstream (render,
  # DSL search, export, the Logs→HEP3 Call-ID extraction) reads clean text.
  test "strips ANSI colour escapes from raw and msg (plain FreeSWITCH line)" do
    line = "#{ESC}[m#{ESC}[mrecv 326 bytes from udp/[54.20.49.188]:5060 at 23:59:12:"
    row = LogTail::Parser.parse(line, pod_hint: "fsw-freeswitch.0")

    assert_equal "recv 326 bytes from udp/[54.20.49.188]:5060 at 23:59:12:", row[:raw]
    assert_equal "recv 326 bytes from udp/[54.20.49.188]:5060 at 23:59:12:", row[:msg]
    refute_includes row[:raw], ESC, "no ESC byte survives to the warehouse"
    refute_match(/\[\d*m/, row[:raw], "no bare CSI colour litter survives")
  end

  test "strips ANSI even with the [pod] prefix and multi-code sequences" do
    line = "[fsw.0] #{ESC}[1;36mNOTICE#{ESC}[0m switch_ivr.c:4404 Hangup"
    row = LogTail::Parser.parse(line)

    assert_equal "fsw.0", row[:pod]
    assert_equal "NOTICE switch_ivr.c:4404 Hangup", row[:msg]
    refute_includes row[:raw], ESC
  end

  test "a Call-ID line is clean so the bridge extracts an uncorrupted id" do
    # An escape wedged next to the value is exactly what breaks the Logs→HEP3
    # chip: the regex would otherwise swallow the CSI bytes into the call_id.
    line = "#{ESC}[msend 364 bytes  Call-ID: #{ESC}[m16948251_133420118@10.1.0.182"
    row = LogTail::Parser.parse(line, pod_hint: "fsw-freeswitch.0")

    assert_equal "16948251_133420118@10.1.0.182", row[:raw][/call-id:\s*([^\s;,]+)/i, 1]
  end

  test "a clean line is returned unchanged (strip is a no-op miss)" do
    row = LogTail::Parser.parse("no escapes here", pod_hint: "web")

    assert_equal "no escapes here", row[:raw]
    assert_equal "no escapes here", row[:msg]
  end
end
