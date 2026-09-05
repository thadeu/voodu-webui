# frozen_string_literal: true

require "test_helper"

# The label for a control that has no visible one.
#
# Most of this file is the accessibility, because the reflex answer is wrong:
# `aria-describedby` is for extra information ABOUT a control that already has
# a name, and here the tooltip text IS the name. Wired that way a screen reader
# announces it twice.
class TooltipTest < ActiveSupport::TestCase
  def render(**opts)
    ApplicationController.render(
      Components::UI::Tooltip.new(label: "Logs", group: "nav", **opts), layout: false
    )
  end

  test "it is hidden from assistive technology" do
    html = render

    assert_includes html, %(role="tooltip")
    assert_includes html, %(aria-hidden="true")

    # NOT describedby-shaped: no id to point at, because nothing should point
    # at it. The trigger carries the accessible name itself.
    assert_not_includes html, "aria-describedby"
  end

  test "it draws an arrow toward the trigger" do
    html = render

    assert_includes html, "rotate-45"

    # A rotated square keeps the bubble's 1px border running around the point.
    # A CSS border-triangle cannot have a border and reads as a smudge.
    assert_includes html, "border-l"
    assert_includes html, "-left-1"
  end

  test "the arrow flips with the side" do
    assert_includes render(side: :left), "-right-1"
    assert_includes render(side: :top), "-bottom-1"
  end

  # THE BUG THIS CONSTANT EXISTS FOR. Tailwind scans SOURCE TEXT for candidate
  # class names, so a class built by interpolation is never generated — the
  # markup is right, the comment is right, and the tooltip is permanently
  # invisible with nothing to grep for.
  test "the reveal class is a literal, not interpolated" do
    Components::UI::Tooltip::HOVER.each_value do |klass|
      assert_match(%r{\Agroup-hover/\w+:opacity-100\z}, klass)

      # And it appears verbatim in this file, which is what Tailwind reads.
      assert_includes File.read(Rails.root.join("app/components/ui/tooltip.rb")), klass
    end
  end

  test "an unregistered group fails loudly rather than rendering nothing" do
    assert_raises(KeyError) do
      ApplicationController.render(
        Components::UI::Tooltip.new(label: "x", group: "nope"), layout: false
      )
    end
  end

  test "the caller can limit when it is drawn" do
    html = render(visible_when: "hidden vmd:group-data-[collapsed]:block")

    assert_includes html, "vmd:group-data-[collapsed]:block"
  end
end
