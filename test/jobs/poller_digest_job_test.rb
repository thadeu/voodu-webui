# frozen_string_literal: true

require "test_helper"

class PollerDigestJobTest < ActiveJob::TestCase
  fixtures :orgs, :islands

  setup do
    @sync_hash = "abcdef0123456789"
    @folder_root = Rails.root.join("storage", "poller")
    @stubs = []
  end

  teardown do
    restore_stubs
    PollerDigest.delete_all
    FileUtils.rm_rf(@folder_root)
  end

  test "dispatches state digest, marks processed, deletes folder" do
    digest = PollerDigest.create!(
      sync_hash: @sync_hash,
      type: "state",
      tenant_id: islands(:alpha).id,
      status: "queued"
    )

    folder = @folder_root.join("state", @sync_hash)
    FileUtils.mkdir_p(folder)
    File.write(folder.join("pods.json"), [].to_json)
    File.write(folder.join("system.json"), {}.to_json)

    called_with = []
    stub_class_method(StateDigestService, :from_folder) do |folder_path:, tenant_id:|
      called_with << {folder_path: folder_path.to_s, tenant_id: tenant_id}
    end

    PollerDigestJob.new.perform(@sync_hash)

    digest.reload
    assert_equal "processed", digest.status
    assert digest.processed_at

    assert_equal 1, called_with.size
    assert_equal folder.to_s, called_with.first[:folder_path]
    assert_equal islands(:alpha).id, called_with.first[:tenant_id]

    refute File.exist?(folder), "expected folder cleanup after success"
  end

  test "dispatches metrics digest by type" do
    PollerDigest.create!(
      sync_hash: @sync_hash,
      type: "metrics",
      tenant_id: islands(:alpha).id,
      status: "queued"
    )

    folder = @folder_root.join("metrics", @sync_hash)
    FileUtils.mkdir_p(folder)
    File.write(folder.join("data.ndjson"), "")

    called = false
    stub_class_method(MetricsDigestService, :from_folder) do |folder_path:, tenant_id:|
      called = true
      0
    end

    PollerDigestJob.new.perform(@sync_hash)

    assert called
  end

  test "discards (raises AlreadyProcessed) on second run" do
    PollerDigest.create!(
      sync_hash: @sync_hash,
      type: "state",
      tenant_id: islands(:alpha).id,
      status: "processed",
      processed_at: Time.current
    )

    assert_raises PollerDigest::AlreadyProcessed do
      PollerDigestJob.new.perform(@sync_hash)
    end
  end

  test "marks failed and re-raises when service blows up" do
    digest = PollerDigest.create!(
      sync_hash: @sync_hash,
      type: "state",
      tenant_id: islands(:alpha).id,
      status: "queued"
    )

    stub_class_method(StateDigestService, :from_folder) do |**_|
      raise "boom"
    end

    assert_raises(RuntimeError) do
      PollerDigestJob.new.perform(@sync_hash)
    end

    digest.reload
    assert_equal "failed", digest.status
    assert_equal "boom", digest.error_message
  end

  private

  # stub_class_method — replaces a class method with the given
  # block AND records the original so `restore_stubs` (called from
  # teardown) puts it back. Important: bare `define_method` +
  # `remove_method` deletes the singleton-class slot entirely (the
  # original `def self.x` is in the same slot), leaving the class
  # with NO method afterwards. We must capture + re-attach the
  # original Method object.
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
