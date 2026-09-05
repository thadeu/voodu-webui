# frozen_string_literal: true

require "test_helper"

# A block that says what KIND of thing it is — without turning the page into a
# colour circus.
#
# The restraint IS the design: the tone rides on a left rule and an icon, and
# the background stays the ordinary surface. Two fully tinted cards on one
# screen read as an incident; four and the operator stops seeing any of them.
# Tint is a volume control, and the blocks this replaced were all set to loud.
class CalloutTest < ActiveSupport::TestCase
  def render(**opts, &block)
    ApplicationController.render(Components::UI::Callout.new(**opts), layout: false, &block)
  end

  test "the tone is a rule and an icon, not a filled card" do
    html = render(tone: :warning, title: "Not deploying here yet")

    assert_includes html, "border-l-voodu-amber"
    assert_includes html, "text-voodu-amber"

    # The background stays ordinary — that is the whole restraint.
    assert_not_includes html, "bg-voodu-amber-dim"
  end

  # `danger` is the exception. A deploy that failed is the one thing on this
  # dashboard that should catch the eye before it is read.
  test "danger keeps a faint fill, and it is the only tone that does" do
    assert_includes render(tone: :danger, title: "x"), "bg-voodu-red-dim"

    %i[info warning success neutral].each do |tone|
      assert_no_match(/bg-voodu-\w+-dim/, render(tone: tone, title: "x"),
        "#{tone} should not be filled")
    end
  end

  test "each tone brings its own glyph" do
    assert_includes render(tone: :info, title: "x"), "aria-hidden=\"true\""
    assert_includes render(tone: :success, title: "x"), "text-voodu-green"
    assert_includes render(tone: :neutral, title: "x"), "text-voodu-muted"
  end

  # The icon is decoration beside a heading that already says it. Announcing
  # it would put "warning warning" in front of a screen reader.
  test "the glyph is hidden from assistive technology" do
    html = render(tone: :warning, title: "Careful")

    assert_match(/<span class="shrink-0 mt-px text-voodu-amber" aria-hidden="true">/, html)
  end

  # A block that is mostly a form does not want an icon beside its heading.
  test "the glyph can be dropped" do
    html = render(tone: :warning, title: "x", icon: false)

    assert_not_includes html, "aria-hidden=\"true\""
  end

  test "an unknown tone falls back to neutral rather than rendering unstyled" do
    html = render(tone: :nonsense, title: "x")

    assert_includes html, "border-l-voodu-border-2"
  end

  test "a title alone is a complete callout" do
    assert_includes render(tone: :info, title: "Just this"), "Just this"
  end
end
