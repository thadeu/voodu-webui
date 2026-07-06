# frozen_string_literal: true

require "test_helper"

# System#plugin_installed? (and Server's delegation) is the gate every
# plugin-specific WebUI feature reads. These pin the behaviour that
# matters: a plugin is found by canonical name OR alias, unknown names
# and old controllers (no `plugins` key) gate OFF, and the gate resolves
# off the locally-synced row with no live call.
class SystemPluginsTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup { @server = servers(:alpha) }

  def attach_system(plugins:)
    payload = {"host" => {}, "plugins" => plugins}
    System.create!(server: @server, payload: payload.to_json, synced_at: Time.current)
    @server.reload
  end

  test "plugin_installed? matches by canonical name" do
    attach_system(plugins: [{"name" => "hep3", "version" => "0.5.0", "aliases" => ["hep"]}])

    assert @server.system.plugin_installed?("hep3")
    assert @server.plugin_installed?("hep3")
  end

  test "plugin_installed? matches by alias" do
    attach_system(plugins: [{"name" => "hep3", "aliases" => ["hep"]}])

    assert @server.plugin_installed?("hep"), "alias should resolve to the plugin"
  end

  test "plugin_installed? is false for an uninstalled plugin" do
    attach_system(plugins: [{"name" => "postgres", "aliases" => ["pg"]}])

    refute @server.plugin_installed?("hep3")
    refute @server.plugin_installed?("hep")
  end

  test "plugin_installed? is false when the controller predates the plugins field" do
    System.create!(server: @server, payload: {"host" => {}}.to_json, synced_at: Time.current)
    @server.reload

    assert_equal [], @server.system.plugins
    refute @server.plugin_installed?("hep3")
  end

  test "plugin_installed? is false when no system snapshot has synced yet" do
    @server.system&.destroy
    @server.reload

    refute @server.plugin_installed?("hep3")
  end

  test "plugin_installed? is false for a blank name" do
    attach_system(plugins: [{"name" => "hep3"}])

    refute @server.plugin_installed?("")
    refute @server.plugin_installed?(nil)
  end

  test "plugins exposes the synced summaries verbatim" do
    attach_system(plugins: [{"name" => "hep3", "version" => "0.5.0", "aliases" => ["hep"]}])

    assert_equal 1, @server.system.plugins.size
    assert_equal "0.5.0", @server.system.plugins.first["version"]
  end
end
