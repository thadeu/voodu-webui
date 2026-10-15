# frozen_string_literal: true

require "test_helper"

# FswapiPageData.group_channels turns FreeSWITCH's flat `show channels` list
# into calls: each A-leg followed by the legs bridged to it. The key is
# call_uuid (a bridge sets both legs' call_uuid to the A-leg's uuid).
class FswapiPageDataTest < ActiveSupport::TestCase
  def leg(uuid, call_uuid, created)
    {"uuid" => uuid, "call_uuid" => call_uuid, "created_epoch" => created.to_s}
  end

  def tree(rows)
    FswapiPageData.group_channels(rows).map { |r| [r["uuid"], r["_leg"], r["_last"]] }
  end

  test "a bridged pair becomes A then B, whatever order FreeSWITCH lists them" do
    rows = [leg("b1", "a1", 101), leg("a1", "a1", 100)]

    assert_equal [["a1", "a", nil], ["b1", "b", true]], tree(rows)
  end

  test "two calls stay apart, each with its own legs" do
    rows = [leg("a1", "a1", 100), leg("a2", "a2", 200), leg("b2", "a2", 201), leg("b1", "a1", 101)]

    assert_equal [["a1", "a", nil], ["b1", "b", true], ["a2", "a", nil], ["b2", "b", true]], tree(rows)
  end

  test "an unbridged leg is a call on its own" do
    rows = [leg("x", "x", 100), leg("y", "", 100)]

    assert_equal [["x", "a", nil], ["y", "a", nil]], tree(rows)
  end

  test "a forked call lists its B-legs oldest first, the last one closes the tree" do
    rows = [leg("b2", "a1", 103), leg("a1", "a1", 100), leg("b1", "a1", 102)]

    assert_equal [["a1", "a", nil], ["b1", "b", false], ["b2", "b", true]], tree(rows)
  end

  test "when the A-leg is gone, the oldest remaining leg leads" do
    rows = [leg("b2", "a1", 105), leg("b1", "a1", 101)]

    assert_equal [["b1", "a", nil], ["b2", "b", true]], tree(rows)
  end

  # ── filter, cap, decode, transcode ──────────────────────────────

  class FakeFswapi
    def initialize(replies) = @replies = replies

    def fswapi(route, _params = nil) = @replies.fetch(route)
  end

  def call(n, codec_b: "PCMA")
    a = "a#{n}"

    [
      {"uuid" => a, "call_uuid" => a, "cid_num" => "5511#{n}", "dest" => "5511#{n}", "read_codec" => "PCMA", "created_epoch" => n.to_s},
      {"uuid" => "b#{n}", "call_uuid" => a, "cid_num" => "5511#{n}", "dest" => "0656%235521#{n}", "read_codec" => codec_b, "created_epoch" => n.to_s}
    ]
  end

  def page(channels, q: nil)
    Rails.cache.clear

    FswapiPageData.new(server: servers(:alpha), view: "channels", q: q,
      client: FakeFswapi.new("channels" => {"rows" => channels}))
  end

  fixtures :orgs, :servers

  test "decode turns FreeSWITCH's %23 back into #, and leaves the rest" do
    assert_equal "0656#552125383939", FswapiPageData.decode("0656%23552125383939")
    assert_equal "+5511999990000", FswapiPageData.decode("+5511999990000")
    assert_equal "", FswapiPageData.decode(nil)
  end

  test "a call whose legs read different codecs is marked as transcoding" do
    data = page(call(1, codec_b: "PCMU") + call(2))

    assert_equal ["PCMA", "PCMU"], data.rows.first["_transcode"]
    assert_equal 1, data.transcoding_count
  end

  test "the filter keeps a whole call when one leg matches, and matches decoded text" do
    data = page(call(1) + call(2), q: "0656#55212")

    assert_equal 1, data.matched_units
    assert_equal 2, data.total_units
    assert_equal %w[a2 b2], data.rows.map { |r| r["uuid"] }
    assert_equal 0, data.rows.first["_group"], "tint restarts at the first shown call"
  end

  test "more than MAX_SHOWN calls are cut, the counts still see them all" do
    channels = (1..(FswapiPageData::MAX_SHOWN + 5)).flat_map { |n| call(n) }
    data = page(channels)

    assert data.capped?
    assert_equal FswapiPageData::MAX_SHOWN, data.rows.count { |r| r["_leg"] == "a" }
    assert_equal FswapiPageData::MAX_SHOWN + 5, data.call_count
    assert_equal (FswapiPageData::MAX_SHOWN + 5) * 2, data.count_for("channels")
  end
end
