# frozen_string_literal: true

require "test_helper"

# LogQuery — the /logs/analytics filter compiler. We assert the compiled
# predicate against hand-built records (the { msg:, raw:, level:, stream: }
# shape the Reader feeds it), covering: the field requirement (every clause
# names @message/@level/@stream), the boolean DSL (and/or/not/parens), regex
# vs substring vs exact, and the graceful degrade when a query names no field.
class LogQueryTest < ActiveSupport::TestCase
  def rec(msg: "", raw: nil, level: "", stream: "")
    { msg: msg, raw: raw || msg, level: level, stream: stream }
  end

  def match?(query, record)
    LogQuery.compile(query).predicate.call(record)
  end

  test "empty query matches everything" do
    assert LogQuery.compile("").predicate.call(rec(msg: "anything"))
    assert LogQuery.compile("   ").predicate.call(rec(msg: "anything"))
  end

  # ── the field requirement ───────────────────────────────────────────────────

  test "a bare regex without a field is invalid (the User-Agent case)" do
    result = LogQuery.compile("/User-Agent/")
    refute result.valid?, "no field → flagged invalid"
    assert result.error.present?
  end

  test "a field-less plain word is invalid but degrades to a substring so results aren't blank" do
    result = LogQuery.compile("callid")
    refute result.valid?, "no field → flagged invalid (legacy ?q= bookmarks still resolve)"
    assert result.predicate.call(rec(msg: "got callid=42 here")), "degrades to a literal @message substring"
  end

  test "the field-scoped form is valid and matches" do
    assert match?("@message like /User-Agent/", rec(msg: "User-Agent: FreeSWITCH"))
    refute match?("@message like /User-Agent/", rec(msg: "Contact: <sip:...>"))
  end

  test "unknown field is an error, not a crash" do
    result = LogQuery.compile('@nope = "x"')
    refute result.valid?
  end

  # ── @message field ──────────────────────────────────────────────────────────

  test "@message like with regex" do
    assert match?("@message like /time(d)?out/", rec(msg: "request timeout"))
    refute match?("@message like /time(d)?out/", rec(msg: "request ok"))
  end

  test "@message covers both msg and raw" do
    assert match?("@message like /dispatcher/", rec(msg: "structured", raw: "From: <sip:dispatcher@localhost>"))
  end

  test "@message with an unquoted value is a substring (implicit like)" do
    assert match?("@message callid", rec(msg: "got callid=42"))
    refute match?("@message callid", rec(msg: "nothing here"))
  end

  # ── boolean DSL ────────────────────────────────────────────────────────────

  test "and requires both clauses" do
    q = "@message like /INVITE/ and @message like /sip/"
    assert match?(q, rec(msg: "INVITE sip:foo"))
    refute match?(q, rec(msg: "INVITE only"))
  end

  test "or accepts either clause" do
    q = "@message like /INVITE/ or @message like /REGISTER/"
    assert match?(q, rec(msg: "REGISTER bar"))
    refute match?(q, rec(msg: "OPTIONS baz"))
  end

  test "not negates a clause" do
    q = "not @message like /health/"
    assert match?(q, rec(msg: "GET /api 200"))
    refute match?(q, rec(msg: "GET /health 200"))
  end

  test "parentheses group precedence" do
    q = "@message like /callid/ or (@message like /200 OK/ and not @message like /OPTIONS/)"
    assert match?(q, rec(msg: "has callid here"))
    assert match?(q, rec(msg: "SIP/2.0 200 OK INVITE"))
    refute match?(q, rec(msg: "SIP/2.0 200 OK OPTIONS"))
    refute match?(q, rec(msg: "unrelated line"))
  end

  # ── pipeline (CloudWatch `filter … | filter …`) ─────────────────────────────

  test "explicit filter command is accepted and equivalent to the bare form" do
    assert match?("filter @message like /User-Agent/", rec(msg: "User-Agent: FreeSWITCH"))
    refute match?("filter @message like /User-Agent/", rec(msg: "Contact: <sip:...>"))
  end

  test "filter is case-insensitive" do
    assert match?("FILTER @message like /INVITE/", rec(msg: "INVITE sip:x"))
  end

  test "two piped filters AND together" do
    q = "filter @message like /INVITE/\n| filter @message like /sip/"
    assert match?(q, rec(msg: "INVITE sip:foo"))
    refute match?(q, rec(msg: "INVITE only")), "second filter must also pass"
    refute match?(q, rec(msg: "sip only")),    "first filter must also pass"
  end

  test "piped stages work without the explicit filter keyword too" do
    q = "@message like /INVITE/ | @message like /sip/"
    assert match?(q, rec(msg: "INVITE sip:foo"))
    refute match?(q, rec(msg: "INVITE only"))
  end

  test "filter stage carries field selectors across the pipe" do
    q = 'filter @level = "ERROR" | filter @message like /timeout/'
    assert match?(q, rec(msg: "upstream timeout", level: "ERROR"))
    refute match?(q, rec(msg: "upstream timeout", level: "WARN"))
    refute match?(q, rec(msg: "all good",         level: "ERROR"))
  end

  test "a pipe inside a regex is part of the pattern, not a stage separator" do
    assert match?("@message like /INVITE|REGISTER/", rec(msg: "REGISTER sip:x"))
    assert match?("@message like /INVITE|REGISTER/", rec(msg: "INVITE sip:x"))
    refute match?("@message like /INVITE|REGISTER/", rec(msg: "OPTIONS sip:x"))
  end

  # ── limit (set operation, surfaced separately from the predicate) ────────────

  test "limit stage is parsed off the predicate and exposed on the result" do
    result = LogQuery.compile("filter @message like /call-id/ | limit 1000")
    assert result.valid?
    assert_equal 1000, result.limit
    # The predicate is just the filter — limit doesn't gate individual rows.
    assert result.predicate.call(rec(msg: "Call-ID: abc"))
    refute result.predicate.call(rec(msg: "nope"))
  end

  test "limit with no filter matches everything and only caps" do
    result = LogQuery.compile("limit 50")
    assert result.valid?
    assert_equal 50, result.limit
    assert result.predicate.call(rec(msg: "anything"))
  end

  test "last limit wins" do
    assert_equal 25, LogQuery.compile("limit 1000 | limit 25").limit
  end

  test "no limit stage leaves limit nil" do
    assert_nil LogQuery.compile("@message like /x/").limit
  end

  test "limit without a positive integer is invalid" do
    refute LogQuery.compile("@message like /x/ | limit").valid?
    refute LogQuery.compile("@message like /x/ | limit abc").valid?
    refute LogQuery.compile("@message like /x/ | limit 0").valid?
  end

  # ── @level / @stream fields ──────────────────────────────────────────────────

  test "@level equality is exact and case-insensitive" do
    assert match?('@level = "error"', rec(msg: "x", level: "ERROR"))
    refute match?('@level = "error"', rec(msg: "x", level: "WARN"))
    refute match?('@level = "err"',   rec(msg: "x", level: "ERROR")) # exact, not substring
  end

  test "@level inequality" do
    assert match?('@level != "INFO"', rec(msg: "x", level: "ERROR"))
    refute match?('@level != "INFO"', rec(msg: "x", level: "INFO"))
  end

  test "combined field + message clause" do
    q = '@level = "ERROR" and @message like /timeout/'
    assert match?(q, rec(msg: "upstream timeout", level: "ERROR"))
    refute match?(q, rec(msg: "upstream timeout", level: "WARN"))
    refute match?(q, rec(msg: "all good",         level: "ERROR"))
  end

  test "@stream selector" do
    assert match?('@stream = "stderr"', rec(msg: "x", stream: "stderr"))
    refute match?('@stream = "stderr"', rec(msg: "x", stream: "stdout"))
  end

  # ── errors degrade gracefully ───────────────────────────────────────────────

  test "incomplete clause falls back to a literal substring and reports the error" do
    result = LogQuery.compile("@message like") # missing value
    refute result.valid?
    assert result.error.present?
    assert result.predicate.call(rec(msg: "x @message like y")), "degrades to literal substring of the input"
  end

  test "unterminated regex degrades but does not raise" do
    result = LogQuery.compile("@message like /unterminated and foo")
    refute result.valid?
    assert_kind_of Proc, result.predicate
  end

  test "invalid regex degrades instead of raising" do
    result = LogQuery.compile("@message like /[/")
    refute result.valid?
    assert_kind_of Proc, result.predicate
  end
end
