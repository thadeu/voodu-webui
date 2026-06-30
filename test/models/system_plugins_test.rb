# frozen_string_literal: true

require "test_helper"

# System#plugin_installed? (and Island's delegation) is the gate every
# plugin-specific WebUI feature reads. These pin the behaviour that
# matters: a plugin is found by canonical name OR alias, unknown names
# and old controllers (no `plugins` key) gate OFF, and the gate resolves
# off the locally-synced row with no live call.
class SystemPluginsTest < ActiveSupport::TestCase
  fixtures :islands

  setup { @island = islands(:alpha) }

  def attach_system(plugins:)
    payload = {"host" => {}, "plugins" => plugins}
    System.create!(island: @island, payload: payload.to_json, synced_at: Time.current)
    @island.reload
  end

  test "plugin_installed? matches by canonical name" do
    attach_system(plugins: [{"name" => "hep3", "version" => "0.5.0", "aliases" => ["hep"]}])

    assert @island.system.plugin_installed?("hep3")
    assert @island.plugin_installed?("hep3")
  end

  test "plugin_installed? matches by alias" do
    attach_system(plugins: [{"name" => "hep3", "aliases" => ["hep"]}])

    assert @island.plugin_installed?("hep"), "alias should resolve to the plugin"
  end

  test "plugin_installed? is false for an uninstalled plugin" do
    attach_system(plugins: [{"name" => "postgres", "aliases" => ["pg"]}])

    refute @island.plugin_installed?("hep3")
    refute @island.plugin_installed?("hep")
  end

  test "plugin_installed? is false when the controller predates the plugins field" do
    System.create!(island: @island, payload: {"host" => {}}.to_json, synced_at: Time.current)
    @island.reload

    assert_equal [], @island.system.plugins
    refute @island.plugin_installed?("hep3")
  end

  test "plugin_installed? is false when no system snapshot has synced yet" do
    @island.system&.destroy
    @island.reload

    refute @island.plugin_installed?("hep3")
  end

  test "plugin_installed? is false for a blank name" do
    attach_system(plugins: [{"name" => "hep3"}])

    refute @island.plugin_installed?("")
    refute @island.plugin_installed?(nil)
  end

  test "plugins exposes the synced summaries verbatim" do
    attach_system(plugins: [{"name" => "hep3", "version" => "0.5.0", "aliases" => ["hep"]}])

    assert_equal 1, @island.system.plugins.size
    assert_equal "0.5.0", @island.system.plugins.first["version"]
  end
end
