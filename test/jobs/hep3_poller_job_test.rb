# frozen_string_literal: true

require "test_helper"

# Hep3PollerJob drains a reader's /export tail into the read model. These
# pin the behaviour that matters: it inserts the lines, advances the
# cursor, NEVER re-reads across ticks (the cardinal sin — duplicates),
# and a malformed line is skipped without stalling the cursor.
class Hep3PollerJobTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  # FakeHepReader models the reader's /export as a byte-offset tail: the
  # cursor is an integer index into the line array, exactly like the real
  # "<file>:<offset>" semantics (returns lines AFTER `since`, empty once
  # caught up). Stands in for Voodu::Client.
  class FakeHepReader
    attr_reader :sinces

    def initialize(lines, page_size: 1000)
      @lines = lines
      @page_size = page_size
      @sinces = []
    end

    def hep_export(_scope, _name, since: nil)
      @sinces << since
      off = since.to_s.empty? ? 0 : Integer(since)
      slice = @lines[off, @page_size] || []
      body = slice.map { |l| "#{l}\n" }.join

      [body, (off + slice.size).to_s]
    end
  end

  setup do
    @server = servers(:alpha)
    @scope = "fsw"
    @name = "hep3-api"
  end

  def sip_line(call_id:, x_cid: "", method: "INVITE", code: 0, ts: "2026-06-30 10:00:00.000000")
    {ts: ts, call_id: call_id, x_cid: x_cid, method: method, response_code: code, raw_sip: "#{method} sip:x"}.to_json
  end

  def run_poll(fake)
    Hep3PollerJob.new.drain(@server, @scope, @name, fake)
  end

  def message_count
    HepMessage.for_instance(server_id: @server.id, scope: @scope, name: @name).count
  end

  test "drains the tail, inserts every line, and advances the cursor" do
    fake = FakeHepReader.new([sip_line(call_id: "a"), sip_line(call_id: "b"), sip_line(call_id: "c")])

    run_poll(fake)

    assert_equal 3, message_count
    assert_equal "3", HepCursor.cursor_for(@server.id, @scope, @name)
  end

  test "a second tick re-reads nothing — no duplicates" do
    fake = FakeHepReader.new([sip_line(call_id: "a"), sip_line(call_id: "b")])

    run_poll(fake)
    assert_equal 2, message_count

    # Same reader, next tick: the persisted cursor drives `since`, so the
    # reader returns empty and nothing is inserted again.
    run_poll(fake)
    assert_equal 2, message_count, "second poll must not re-insert"
    assert_equal "2", fake.sinces.last, "second tick resumes from the persisted cursor"
  end

  test "skips a malformed line but still advances the cursor past it" do
    fake = FakeHepReader.new([sip_line(call_id: "a"), "this is not json {", sip_line(call_id: "b")])

    run_poll(fake)

    assert_equal 2, message_count, "the garbage line is dropped, the 2 valid lines land"
    assert_equal "3", HepCursor.cursor_for(@server.id, @scope, @name),
      "cursor reflects lines consumed (incl. the skipped one) so it never re-reads"
  end

  test "a caught-up reader is a no-op" do
    HepCursor.advance(@server.id, @scope, @name, "5")
    fake = FakeHepReader.new([sip_line(call_id: "a")], page_size: 1000)
    # since='5' is past the single line → empty.
    run_poll(fake)

    assert_equal 0, message_count
  end
end
