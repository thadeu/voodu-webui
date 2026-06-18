# frozen_string_literal: true

require "test_helper"

# Pins LogTail::LineFormatter — the shared serialiser behind the
# analytics export. ndjson keeps the FULL record; csv/txt project the
# 5-field shape; csv stays RFC-4180 safe.
class LogTail::LineFormatterTest < ActiveSupport::TestCase
  REC = {
    ts: "2026-06-09T15:00:00.000Z",
    pod: "web",
    stream: "stdout",
    level: "INFO",
    msg: "hi, \"world\"",
    raw: "raw original line",
    parsed: true
  }.freeze

  test "ndjson emits the full record, one JSON object + newline" do
    line = LogTail::LineFormatter.line(REC, "ndjson")
    assert line.end_with?("\n")

    parsed = JSON.parse(line.chomp)
    assert_equal "raw original line", parsed["raw"], "raw context survives"
    assert_equal true, parsed["parsed"]
    assert_equal "web", parsed["pod"]
  end

  test "csv has a column header and quotes commas/quotes" do
    assert_equal "ts,pod,stream,level,msg\n", LogTail::LineFormatter.header("csv")

    line = LogTail::LineFormatter.line(REC, "csv")
    row = CSV.parse_line(line)
    assert_equal %w[ts pod stream level], LogTail::LineFormatter::CSV_COLUMNS[0, 4]
    assert_equal "web", row[1]
    assert_equal "hi, \"world\"", row[4], "comma + quotes round-trip through CSV"
  end

  test "txt is 'ts [pod] LEVEL msg' and omits level when blank" do
    assert_equal "2026-06-09T15:00:00.000Z [web] INFO hi, \"world\"\n", LogTail::LineFormatter.line(REC, "txt")

    plain = LogTail::LineFormatter.line(REC.merge(level: nil), "txt")
    assert_equal "2026-06-09T15:00:00.000Z [web] hi, \"world\"\n", plain
  end

  test "ndjson is the default + only csv has a header" do
    assert_nil LogTail::LineFormatter.header("ndjson")
    assert_nil LogTail::LineFormatter.header("txt")
    assert_equal LogTail::LineFormatter.line(REC, "anything"), LogTail::LineFormatter.line(REC, "ndjson")
  end

  test "row_hash reads string-keyed records (Reader shape)" do
    str = {"ts" => "t", "pod" => "p", "stream" => "s", "level" => "INFO", "msg" => "m"}
    assert_equal({ts: "t", pod: "p", stream: "s", level: "INFO", msg: "m"}, LogTail::LineFormatter.row_hash(str))
  end
end
