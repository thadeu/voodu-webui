# frozen_string_literal: true

require "test_helper"

# DataTable::HttpSource maps an external API response into DataTable rows (table)
# or timeseries points (chart), STATELESSLY — the response is the render. Pins
# the mapping, the outbound query contract (from/until/interval/scope/label),
# and that a failed fetch surfaces (FetchError for rows, [] for a chart). The
# outbound HTTP is stubbed — these test the mapping, not the network.
class DataTable::HttpSourceTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup { @server = servers(:alpha) }

  SERIES_JSON = {
    "data" => {"points" => [
      {"t" => "2025-07-02T12:02:00Z", "v" => 5, "host" => "web-2"},
      {"t" => "2025-07-02T12:00:00Z", "v" => 9, "host" => "web-1"}
    ]}
  }.freeze

  def source(mapping, **panel)
    DataTable::HttpSource.new(server: @server, panel: {"url" => "http://ext/api", "mapping" => mapping}.merge(panel))
  end

  # stub_fetch — swap HttpFetch.call for `impl` (or a canned result) for the
  # block, then restore. Avoids minitest/mock (broken under minitest 6 here).
  def stub_fetch(json: nil, ok: true, error: nil, impl: nil)
    impl ||= ->(**_kw) { DataTable::HttpFetch::Result.new(ok: ok, json: json, error: error) }
    original = DataTable::HttpFetch.method(:call)
    DataTable::HttpFetch.define_singleton_method(:call, impl)

    yield
  ensure
    DataTable::HttpFetch.define_singleton_method(:call, original)
  end

  test "rows: maps root + columns into flat string rows, id = array index" do
    src = source({"root" => "data.points", "columns" => [
      {"field" => "host", "path" => "host"}, {"field" => "v", "path" => "v"}
    ]})

    rows = stub_fetch(json: SERIES_JSON) { src.rows }

    assert_equal 2, rows.size
    assert_equal({"id" => 0, "host" => "web-2", "v" => "5"}, rows.first)
    assert_equal %w[host v], src.fields, "columns drive the field list"
  end

  test "series: maps ts + value, sorts by ts, normalises the timestamp" do
    src = source({"root" => "data.points", "ts" => "t", "value" => "v"})

    points = stub_fetch(json: SERIES_JSON) { src.series }

    assert_equal 2, points.size
    assert_equal "2025-07-02T12:00:00.000Z", points.first[:ts], "sorted oldest-first, ISO-normalised"
    assert_equal 9.0, points.first[:value]
  end

  test "series: a point missing its ts is dropped, not rendered at epoch 0" do
    json = {"pts" => [{"v" => 1}, {"t" => "2025-07-02T12:00:00Z", "v" => 2}]}
    src = source({"root" => "pts", "ts" => "t", "value" => "v"})

    points = stub_fetch(json: json) { src.series }

    assert_equal 1, points.size
    assert_equal 2.0, points.first[:value]
  end

  test "a failed fetch raises FetchError for rows but degrades to [] for a chart" do
    src = source({"root" => "x", "columns" => []})

    stub_fetch(ok: false, error: "request timed out after 10s") do
      err = assert_raises(DataTable::HttpSource::FetchError) { src.rows }
      assert_equal "request timed out after 10s", err.message

      assert_empty src.series
    end
  end

  test "the outbound request carries the window (from/until ISO), interval, scope, label" do
    src = source({"root" => "data.points", "columns" => []}, "scope" => "prod", "label" => "Calls", "interval" => "auto")
    captured = nil
    grab = ->(**kw) {
      captured = kw
      DataTable::HttpFetch::Result.new(ok: true, json: {})
    }

    stub_fetch(impl: grab) { src.rows(ts_from: 1_751_457_600, ts_to: 1_751_461_200) }

    assert_equal "2025-07-02T12:00:00Z", captured[:query]["from"]
    assert_equal "2025-07-02T13:00:00Z", captured[:query]["until"]
    assert_equal "60s", captured[:query]["interval"], "auto resolves to a concrete bucket"
    assert_equal "prod", captured[:query]["scope"]
    assert_equal "Calls", captured[:query]["label"]
  end

  test "preview returns BOTH the raw response and the mapped output (the Test loop)" do
    src = source({"root" => "data.points", "ts" => "t", "value" => "v"})

    preview = stub_fetch(json: SERIES_JSON) { src.preview(chart: true) }

    assert preview.ok?
    assert_equal SERIES_JSON, preview.raw, "raw = the shape the operator maps against"
    assert_equal 2, preview.series.size, "series = the mapped output, confirming the paths resolve"
  end

  # ── Builder-preview token resolution (locate_panel) ──────────────────────────
  # An in-progress http panel isn't persisted, so metrics#preview caches its
  # config under an org-scoped token and hands the card "preview-<token>".
  # from_params resolves that from the cache, so the preview's rows fetch works
  # without the url/auth-headers ever reaching the client.

  # with_cache — swap Rails.cache for a real store for the block (test env's
  # :null_store swallows writes). Mirrors stub_fetch; avoids minitest/mock.
  def with_cache(store)
    original = Rails.method(:cache)
    Rails.define_singleton_method(:cache, -> { store })

    yield
  ensure
    Rails.define_singleton_method(:cache, original)
  end

  test "from_params resolves a preview-<token> panel from the org-scoped cache" do
    panel = {"url" => "http://ext/api", "mapping" => {"root" => "", "columns" => []}}
    store = ActiveSupport::Cache::MemoryStore.new
    store.write(DataTable::HttpSource.preview_cache_key(@server.org_id, "tok123"), panel)

    with_cache(store) do
      src = DataTable::HttpSource.from_params(server: @server, params: {dashboard: "preview-tok123"})

      assert_instance_of DataTable::HttpSource, src, "the cached panel builds a live source"
    end
  end

  test "a preview token minted for ANOTHER org never resolves for this server" do
    panel = {"url" => "http://ext/api", "mapping" => {}}
    store = ActiveSupport::Cache::MemoryStore.new
    store.write(DataTable::HttpSource.preview_cache_key("some-other-org", "tok123"), panel)

    with_cache(store) do
      assert_nil DataTable::HttpSource.from_params(server: @server, params: {dashboard: "preview-tok123"}),
        "the cache key is org-scoped — a token from another org is a miss"
    end
  end

  test "an unknown/expired preview token resolves to nil, not a crash" do
    with_cache(ActiveSupport::Cache::MemoryStore.new) do
      assert_nil DataTable::HttpSource.from_params(server: @server, params: {dashboard: "preview-missing"})
    end
  end
end
