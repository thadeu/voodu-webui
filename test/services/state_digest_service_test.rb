# frozen_string_literal: true

require "test_helper"

class StateDigestServiceTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @folder = Rails.root.join("tmp", "test", "state-digest-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@folder)
    @stubs = []
  end

  teardown do
    restore_stubs
    FileUtils.rm_rf(@folder)
    Pod.where(server_id: @server.id).delete_all
    System.where(server_id: @server.id).delete_all
  end

  test "from_folder replaces pod + system snapshots" do
    pods = [
      {
        "name" => "voodu-x-web.a3f9",
        "kind" => "deployment",
        "scope" => "x",
        "resource_name" => "web",
        "replica_id" => "a3f9"
      }
    ]
    system = {"host" => {"hostname" => "node-1"}, "uptime_seconds" => 12_345}

    # Wire shape pin: Go binary writes the full PAT envelope, NOT the
    # unwrapped Array/Hash. The service must peel `data.pods` /
    # `data` before handing off to PodSnapshot/SystemSnapshot —
    # otherwise build_rows iterates over envelope keys and blows up
    # with TypeError on `String#[]`.
    File.write(@folder.join("pods.json"),
      {"status" => "ok", "data" => {"pods" => pods, "degraded" => []}}.to_json)
    File.write(@folder.join("system.json"),
      {"status" => "ok", "data" => system}.to_json)

    stub_class_method(Turbo::StreamsChannel, :broadcast_action_to) { |*| }
    stub_class_method(Turbo::StreamsChannel, :broadcast_update_to) { |*| }

    StateDigestService.from_folder(folder_path: @folder, server_id: @server.id)

    assert_equal 1, Pod.where(server_id: @server.id).count
    assert_equal "voodu-x-web.a3f9",
      Pod.where(server_id: @server.id).first.container_name

    assert System.find_by(server_id: @server.id), "system snapshot must exist"
  end

  test "from_parsed broadcasts state_tick + status updates" do
    captured = []
    stub_class_method(Turbo::StreamsChannel, :broadcast_update_to) do |stream, **kwargs|
      captured << {stream: stream, kind: :update, kwargs: kwargs}
    end
    stub_class_method(Turbo::StreamsChannel, :broadcast_action_to) do |stream, **kwargs|
      captured << {stream: stream, kind: :action, kwargs: kwargs}
    end

    StateDigestService.from_parsed(pods: [], system: {}, server_id: @server.id)

    stream = "server-state-#{@server.id}"
    assert captured.any? { |b| b[:stream] == stream && b[:kind] == :action },
      "expected state_tick action broadcast"
    assert captured.any? { |b| b[:stream] == stream && b[:kind] == :update },
      "expected status pill/dot update broadcasts"
  end

  test "from_folder tolerates missing files (defaults to empty)" do
    stub_class_method(Turbo::StreamsChannel, :broadcast_action_to) { |*| }
    stub_class_method(Turbo::StreamsChannel, :broadcast_update_to) { |*| }

    assert_nothing_raised do
      StateDigestService.from_folder(folder_path: @folder, server_id: @server.id)
    end
  end

  test "from_parsed returns nil for unknown server" do
    assert_nil StateDigestService.from_parsed(pods: [], system: {}, server_id: -1)
  end

  private

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
