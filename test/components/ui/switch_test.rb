# frozen_string_literal: true

require "test_helper"

class Components::UI::SwitchTest < ActiveSupport::TestCase
  test "renders a hidden peer checkbox with a track + knob" do
    html = Components::UI::Switch.new.call

    assert_includes html, 'type="checkbox"'
    assert_includes html, "peer sr-only", "the control is a visually-hidden peer checkbox"
    assert_includes html, "peer-checked:bg-voodu-accent", "track lights up when checked"
    assert_includes html, "peer-checked:translate-x-[14px]", "knob slides when checked"
  end

  test "checked: reflects onto the input" do
    assert_match(/<input[^>]*\schecked/, Components::UI::Switch.new(checked: true).call)
    assert_no_match(/<input[^>]*\schecked/, Components::UI::Switch.new(checked: false).call)
  end

  # Drop-in for a native checkbox: any input attribute flows through.
  test "passes data / name / aria attributes through to the input" do
    html = Components::UI::Switch.new(
      data: {panel_options_target: "dots", action: "change->x#y"},
      name: "toggle", aria: {label: "Toggle dots"}
    ).call

    assert_includes html, 'data-panel-options-target="dots"'
    assert_includes html, 'name="toggle"'
    assert_includes html, 'aria-label="Toggle dots"'
  end
end
