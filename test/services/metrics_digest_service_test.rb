# frozen_string_literal: true

require "test_helper"

class MetricsDigestServiceTest < ActiveSupport::TestCase
  fixtures :islands

  setup do
    MetricSample.delete_all
    @island = islands(:alpha)
    @folder = Rails.root.join("tmp", "test", "metrics-digest-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@folder)
    @stubs = []
  end

  teardown do
    restore_stubs
    FileUtils.rm_rf(@folder)
    MetricSample.delete_all
  end

  test "from_folder ingests NDJSON rows and broadcasts metrics_tick" do
    File.write(@folder.join("data.ndjson"), <<~NDJSON)
      {"ts":"2026-05-28T10:00:00Z","source":"system","cpu_percent":42}
      {"ts":"2026-05-28T10:00:15Z","source":"system","cpu_percent":43}
    NDJSON

    captured = []
    stub_class_method(Turbo::StreamsChannel, :broadcast_action_to) do |stream, **kwargs|
      captured << {stream: stream, kwargs: kwargs}
    end

    total = MetricsDigestService.from_folder(folder_path: @folder, tenant_id: @island.id)
    assert_equal 2, total
    assert_equal 2, MetricSample.where(tenant_id: @island.id).count

    expected_stream = "metrics-#{@island.id}"
    assert captured.any? { |c| c[:stream] == expected_stream },
      "expected broadcast_action_to(#{expected_stream})"
  end

  test "from_io skips malformed and empty lines" do
    io = StringIO.new(<<~NDJSON)
      {"ts":"2026-05-28T10:00:00Z","source":"system","cpu_percent":42}

      this-is-not-json
      {"ts":"","source":"system"}
      {"ts":"2026-05-28T10:00:30Z","source":"system","cpu_percent":44}
    NDJSON

    stub_class_method(Turbo::StreamsChannel, :broadcast_action_to) { |*| }

    total = MetricsDigestService.from_io(io: io, tenant_id: @island.id)
    assert_equal 2, total
    assert_equal 2, MetricSample.where(tenant_id: @island.id).count
  end

  test "ingest_lines accepts pre-parsed Hash rows" do
    rows = [
      {source: "system", ts_iso: "2026-05-28T10:00:00Z", payload: '{"ts":"2026-05-28T10:00:00Z","source":"system"}'},
      {source: "system", ts_iso: "2026-05-28T10:00:15Z", payload: '{"ts":"2026-05-28T10:00:15Z","source":"system"}'}
    ]

    stub_class_method(Turbo::StreamsChannel, :broadcast_action_to) { |*| }

    total = MetricsDigestService.ingest_lines(island: @island, rows: rows)
    assert_equal 2, total
  end

  test "from_folder returns 0 when ndjson missing" do
    total = MetricsDigestService.from_folder(folder_path: @folder, tenant_id: @island.id)
    assert_equal 0, total
  end

  private

  # See PollerDigestJobTest for the rationale on UnboundMethod-based
  # restore (bare define_method + remove_method removes the original
  # too, because `def self.x` lives in the same singleton slot).
  def stub_class_method(klass, name, &block)
    original = klass.singleton_class.instance_method(name)
    klass.singleton_class.define_method(name, &block)
    @stubs << [klass, name, original]
  end

  def restore_stubs
    while (entry = @stubs&.pop)
      klass, name, original = entry
      klass.singleton_class.define_method(name, original)
    end
  end
end
