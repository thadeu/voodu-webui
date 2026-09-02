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
end
