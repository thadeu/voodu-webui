# frozen_string_literal: true

require "test_helper"

class AlertHistoryFilterTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 6, 10, 12, 0, 0)

  setup { travel_to NOW }
  teardown { travel_back }

  test "defaults to 7d when no params given" do
    f = AlertHistoryFilter.new

    assert_equal "7d", f.range
    assert_not f.custom?
    assert_in_delta((NOW - 7.days).to_f, f.from.to_f, 1)
    assert_in_delta NOW.to_f, f.until_.to_f, 1
  end

  test "unknown range falls back to default" do
    assert_equal "7d", AlertHistoryFilter.new(range: "bogus").range
  end

  test "accepts known presets" do
    assert_equal "24h", AlertHistoryFilter.new(range: "24h").range
    assert_equal "30d", AlertHistoryFilter.new(range: "30d").range
    assert_in_delta((NOW - 24.hours).to_f, AlertHistoryFilter.new(range: "24h").from.to_f, 1)
  end

  test "explicit custom range uses the parsed window" do
    f = AlertHistoryFilter.new(
      range: "custom",
      from:  "2026-06-08T00:00:00.000Z",
      until: "2026-06-09T00:00:00.000Z"
    )

    assert f.custom?
    assert_equal Time.utc(2026, 6, 8).to_i, f.from.to_i
    assert_equal Time.utc(2026, 6, 9).to_i, f.until_.to_i
  end

  test "a bare from/until with no range reads as custom" do
    f = AlertHistoryFilter.new(from: "2026-06-08T00:00:00.000Z", until: "2026-06-09T00:00:00.000Z")

    assert f.custom?
  end

  test "custom stays custom even with a blank from (defaults to a day before until)" do
    f = AlertHistoryFilter.new(range: "custom", until: "2026-06-09T00:00:00.000Z")

    assert f.custom?
    assert_equal Time.utc(2026, 6, 8).to_i, f.from.to_i
  end

  test "iso accessors emit UTC" do
    f = AlertHistoryFilter.new(range: "24h")

    assert_match(/Z\z/, f.from_iso)
    assert_match(/Z\z/, f.until_iso)
  end
end
