# frozen_string_literal: true

require "test_helper"

# Components::UI::Select — flat options (unchanged) and grouped options.
class UISelectTest < ActiveSupport::TestCase
  def render(**opts)
    ApplicationController.render(Components::UI::Select.new(name: "metric", **opts), layout: false)
  end

  GROUPS = [
    ["General", [["cpu", "CPU usage (%)"]]],
    ["FreeSWITCH", [["fs_calls", "Active calls", "FreeSWITCH · Active calls"]]]
  ].freeze

  test "flat options render as before, no group markup" do
    html = render(options: [["a", "Alpha"], ["b", "Beta"]], selected: "b")

    assert_includes html, "Beta"
    assert_not_includes html, "data-group-label"
  end

  test "groups render a labelled heading per group, in order" do
    html = render(groups: GROUPS, selected: "cpu")

    assert_match %r{role="group" aria-labelledby="metric-general"}, html
    assert_match %r{id="metric-general"[^>]*>General<}, html
    assert_operator html.index(">General<"), :<, html.index(">FreeSWITCH<")
  end

  test "the closed select shows the option's title, the menu its short label" do
    html = render(groups: GROUPS, selected: "fs_calls")

    assert_match %r{data-ds-select-target="label"[^>]*>FreeSWITCH · Active calls<}, html
    assert_match %r{data-label="FreeSWITCH · Active calls"}, html
    assert_match %r{>Active calls</span>}, html
  end
end
