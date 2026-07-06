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
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  def attach_system(plugins:)
    System.create!(
      server: @server,
      payload: {"host" => {}, "plugins" => plugins}.to_json,
      synced_at: Time.current
    )
  end

  test "lists installed plugins from the synced /system payload" do
    attach_system(plugins: [{"name" => "hep3", "version" => "0.5.0", "aliases" => ["hep"]}])

    get settings_path(server_key: @key)

    assert_response :success
    assert_match "Plugins", @response.body
    assert_match "hep3", @response.body
    assert_match "v0.5.0", @response.body
    assert_match "(hep)", @response.body

    # Placement: the Plugins card sits below API Tokens and ABOVE the
    # Server/About pair — "Endpoint" is a Server-card label, so the
    # plugins must appear before it in the document.
    assert_operator @response.body.index("Plugins"), :<, @response.body.index("Endpoint"),
      "Plugins card should render above the Server card"
  end

  test "shows an empty state when no plugins are installed" do
    attach_system(plugins: [])

    get settings_path(server_key: @key)

    assert_response :success
    assert_match "No plugins installed", @response.body
  end
end
