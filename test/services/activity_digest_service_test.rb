# frozen_string_literal: true

require "test_helper"

class ActivityDigestServiceTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    ActivityAction.delete_all
    @server = servers(:alpha)
    @folder = Rails.root.join("tmp", "test", "activity-digest-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@folder)
    @stubs = []
  end

  teardown do
    restore_stubs
    FileUtils.rm_rf(@folder)
    ActivityAction.delete_all
  end

  def write_ndjson(*lines)
    File.write(@folder.join("data.ndjson"), lines.join("\n") + "\n")
  end

  def ingest
    ActivityDigestService.from_folder(folder_path: @folder, server_id: @server.id)
  end

  def line(**attrs)
    {"id" => "a1", "ts" => "2026-09-02T10:00:00Z", "event" => "done",
     "action" => "apply", "origin" => "cli"}.merge(attrs.transform_keys(&:to_s)).to_json
  end

  test "a started and its finished collapse into one row" do
    write_ndjson(
      line(id: "a1", event: "started", ts: "2026-09-02T10:00:00Z"),
      line(id: "a1", event: "finished", ts: "2026-09-02T10:00:20Z",
        status: "succeeded", elapsed_ms: 20_000, name: "web", scope: "acme")
    )

    ingest

    assert_equal 1, ActivityAction.count, "the pair should be one action, not two rows"

    row = ActivityAction.first
    assert_equal "finished", row.event
    assert_equal "succeeded", row.status
    assert_equal "web", row.name
    assert_equal 20.0, row.duration
  end

  test "the pair collapses across two separate digests" do
    write_ndjson(line(id: "a1", event: "started"))
    ingest

    # `now` pinned relative to the line's own ts: in_flight? is a question
    # about age, so against the wall clock this assertion would start failing
    # an hour after the fixture timestamp.
    just_after = Time.utc(2026, 9, 2, 10, 0, 30)
    assert ActivityAction.first.in_flight?(now: just_after), "a lone started is in flight"

    long_after = Time.utc(2026, 9, 2, 12, 0, 0)
    assert_equal ActivityAction::UNKNOWN, ActivityAction.first.effective_status(now: long_after),
      "a started nobody ever closed must stop claiming to be running"

    write_ndjson(line(id: "a1", event: "finished", ts: "2026-09-02T10:00:20Z", status: "failed", error: "boom"))
    ingest

    assert_equal 1, ActivityAction.count

    row = ActivityAction.first
    assert_equal "failed", row.effective_status
    assert_equal "boom", row.error_message
  end

  # The guard. The poller's watermark is in-memory and a restart reaches back,
  # so an old `started` WILL arrive again after its `finished` landed. If it
  # won, the row would claim to be running and never stop.
  test "a re-delivered started does not revert a finished action" do
    write_ndjson(
      line(id: "a1", event: "started"),
      line(id: "a1", event: "finished", ts: "2026-09-02T10:00:20Z", status: "succeeded")
    )
    ingest

    write_ndjson(line(id: "a1", event: "started"))
    ingest

    row = ActivityAction.first
    assert_equal "finished", row.event
    assert_equal "succeeded", row.status
  end

  # Re-delivery is not an error case here, it is the normal case: the fetcher
  # overlaps the boundary on purpose so a line sharing the newest timestamp is
  # never skipped.
  test "ingesting the same digest twice changes nothing" do
    write_ndjson(
      line(id: "a1", event: "done", action: "delete"),
      line(id: "a2", event: "done", action: "rollback")
    )

    ingest
    ingest

    assert_equal 2, ActivityAction.count
  end

  # One `vd config set A=1 B=2` writes a line per key sharing one id. Keyed on
  # the id alone the second key would overwrite the first, and the screen would
  # show one change where two happened.
  test "config keys sharing one command id stay separate rows" do
    write_ndjson(
      line(id: "c1", action: "config.set", config_key: "DATABASE_URL", value_digest: "aa11bb", scope: "acme"),
      line(id: "c1", action: "config.set", config_key: "NODE_ENV", value_digest: "cc22dd", scope: "acme")
    )

    ingest

    assert_equal 2, ActivityAction.count
    assert_equal %w[DATABASE_URL NODE_ENV], ActivityAction.order(:config_key).pluck(:config_key)
  end

  test "a non-config action stores an empty config key, never null" do
    write_ndjson(line(id: "a1", action: "restart"))

    ingest

    assert_equal "", ActivityAction.first.config_key,
      "NULL would be distinct in the unique index and re-delivery would duplicate the row"
  end

  test "malformed and incomplete lines are skipped, not fatal" do
    write_ndjson(
      "not json at all",
      {"ts" => "2026-09-02T10:00:00Z"}.to_json,
      line(id: "a1", event: "sideways"),
      line(id: "ok1", action: "delete")
    )

    assert_equal 1, ingest
    assert_equal ["ok1"], ActivityAction.pluck(:activity_id)
  end

  test "ingest broadcasts an activity tick so a running action resolves itself" do
    captured = []
    stub_class_method(Turbo::StreamsChannel, :broadcast_action_to) do |stream, **kwargs|
      captured << {stream: stream, kwargs: kwargs}
    end

    write_ndjson(line(id: "a1"))
    ingest

    assert captured.any? { |c| c[:stream] == "activity-#{@server.id}" },
      "expected broadcast_action_to(activity-#{@server.id})"
  end

  test "an empty digest broadcasts nothing" do
    captured = []
    stub_class_method(Turbo::StreamsChannel, :broadcast_action_to) do |stream, **|
      captured << stream
    end

    write_ndjson("")

    assert_equal 0, ingest
    assert_empty captured
  end

  test "the watermark is the newest action timestamp" do
    write_ndjson(
      line(id: "a1", ts: "2026-09-02T10:00:00Z"),
      line(id: "a2", ts: "2026-09-02T10:05:00Z")
    )
    ingest

    assert_equal Time.utc(2026, 9, 2, 10, 5).to_i, ActivityAction.last_ts_for(@server)
  end

  test "the watermark is zero for a server with no trail" do
    assert_equal 0, ActivityAction.last_ts_for(@server)
  end

  # Stubbing the broadcast without a gem, the way the sibling digest test does:
  # swap the singleton method and put the original UnboundMethod back, because
  # remove_method on a `def self.x` slot would take the original with it.
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

  # The screen must never be the hole the file format closed.
  test "a config value never reaches the warehouse" do
    write_ndjson(line(id: "c1", action: "config.set",
      config_keys: [{"key" => "DATABASE_URL", "value_digest" => "aa11bb"}]))
    ingest

    row = ActivityAction.first

    assert_equal [{"key" => "DATABASE_URL", "value_digest" => "aa11bb"}], row.config_changes
    assert_nil row.payload_json["value"], "the controller does not send a value; nothing should invent one"
  end

  # The controller now writes ONE line per config COMMAND carrying every key.
  # Rows in the older per-key shape are still inside the 30-day window, so the
  # reader answers for both until they age out.
  test "a config command carrying several keys lands as one row" do
    write_ndjson(line(id: "c1", action: "config.set", scope: "runa", name: "pg",
      config_keys: [
        {"key" => "VAR", "value_digest" => "aa11"},
        {"key" => "VAR1", "value_digest" => "bb22"},
        {"key" => "VAR2", "value_digest" => "cc33"}
      ]))

    ingest

    assert_equal 1, ActivityAction.count, "one command must be one row"

    row = ActivityAction.first

    assert_equal %w[VAR VAR1 VAR2], row.config_keys
    assert_equal "3 vars", row.target
    assert_equal "pg", row.app
  end

  test "a row written in the older per-key shape still reads back" do
    write_ndjson(line(id: "c1", action: "config.set", config_key: "LEGACY_KEY", value_digest: "dd44"))

    ingest

    row = ActivityAction.first

    assert_equal ["LEGACY_KEY"], row.config_keys
    assert_equal "LEGACY_KEY", row.target
  end
end
