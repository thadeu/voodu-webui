# frozen_string_literal: true

require "test_helper"

# Settings lists the plugins installed on the focused server, read from
# the locally-synced /system payload (warehouse mode keeps the render off
# the network). Pins that the card shows the synced plugins and degrades
# to an empty state — the same list backs the plugin feature gates.
class SettingsControllerTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @key = @server.key
  end

  def attach_system(plugins:)
    System.create!(
      server: @server,
      payload: {"host" => {}, "plugins" => plugins}.to_json,
      synced_at: Time.current
    )
  end

  class FakePruneClient
    def initialize(result) = @result = result

    def prune_images
      raise @result if @result.is_a?(StandardError)

      @result
    end
  end

  test "clean up images reports what the box removed" do
    report = {"removed" => ["a:1", "a:2"], "errors" => [], "reclaimed_bytes" => 2048}

    Voodu::Client.stub(:new, FakePruneClient.new(report)) do
      post prune_images_settings_path(server_key: @key)
    end

    assert_redirected_to settings_path(server_key: @key)
    assert_match "Removed 2 image tags", flash[:notice]
  end

  test "clean up images shows the box's refusal" do
    error = Voodu::Client::Error.new("image prune already running")

    Voodu::Client.stub(:new, FakePruneClient.new(error)) do
      post prune_images_settings_path(server_key: @key)
    end

    assert_match "already running", flash[:alert]
  end
end
