# frozen_string_literal: true

require "test_helper"

# IslandHealth.status_for is READ-ONLY — a cache read, :unknown on a miss,
# never a synchronous probe (that would block every page render on N
# unreachable controllers). The one on-demand probe is refresh!.
#
# WebMock (test_helper) times out the default outbound call, so an
# un-stubbed probe resolves to :offline via refresh!'s rescue.
class IslandHealthTest < ActiveSupport::TestCase
  fixtures :islands

  setup { @island = islands(:alpha) }

  test "status_for returns :unknown on a cold cache, without probing" do
    # :unknown (not :offline) is the proof no probe ran — a probe would
    # time out and warm :offline. The null_store test cache is always cold.
    assert_equal :unknown, IslandHealth.status_for(@island)
  end

  test "status_for reads the cached status, never the network" do
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    IslandHealth.warm(@island, online: true)

    assert_equal :online, IslandHealth.status_for(@island)
  ensure
    Rails.cache = original
  end

  test "refresh! probes and reads :offline when the agent is unreachable" do
    assert_equal :offline, IslandHealth.refresh!(@island)
  end

  test "refresh! reads :online when the agent's /system responds" do
    stub_request(:get, %r{/api/pat/v1/system\z}).to_return(
      status: 200, body: "{}", headers: {"Content-Type" => "application/json"}
    )

    assert_equal :online, IslandHealth.refresh!(@island)
  end
end
