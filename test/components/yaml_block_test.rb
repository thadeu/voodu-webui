# frozen_string_literal: true

require "test_helper"

# The trigger-file viewer: color, and the copy that has to reproduce the file
# byte for byte.
#
# Hand-rolled rather than a gem because the input is not arbitrary — it is
# `spec.to_yaml`, re-serialized by us from a struct the box already validated.
# These tests are what keeps that claim honest: anything the tokeniser does not
# recognize must come through as plain text, never dropped.
class YamlBlockTest < ActiveSupport::TestCase
  def render(text, **opts)
    ApplicationController.render(
      Components::Deploys::YamlBlock.new(text: text, **opts), layout: false
    )
  end

  test "keys, strings, numbers and booleans are told apart" do
    html = render("name: Web\nreplicas: 3\nenabled: true\n")

    assert_includes html, %(<span class="text-voodu-blue">name</span>)
    assert_includes html, %(<span class="text-voodu-green">Web</span>)
    assert_includes html, %(<span class="text-voodu-amber">3</span>)
    assert_includes html, %(<span class="text-voodu-purple">true</span>)
  end

  test "a comment line is muted whole" do
    html = render("# the web app\nname: Web\n")

    assert_includes html, %(<span class="text-voodu-muted-2"># the web app</span>)
  end

  # `#` inside a quoted value is not a comment. Splitting naively would show
  # the operator a file name that is not theirs.
  test "a hash inside a value is not treated as a comment" do
    html = render(%(file: "a#b.hcl"\n))

    assert_includes html, "a#b.hcl"
    assert_not_includes html, %(<span class="text-voodu-muted-2">#b.hcl")
  end

  test "a trailing comment is muted while the value keeps its color" do
    html = render("name: Web # the front end\n")

    assert_includes html, %(<span class="text-voodu-green">Web </span>)
    assert_includes html, %(<span class="text-voodu-muted-2"># the front end</span>)
  end

  # THE PROPERTY THAT MATTERS MOST. Color is a nicety; a copy button that
  # hands back something other than the file is a trap — somebody pastes it
  # into their repository and wonders why the deploy changed.
  test "the copy button carries the text unchanged" do
    text = "name: Web\non:\n  push:\n    branches: [main]\n"
    html = render(text, path: ".voodu/web.yml")

    assert_includes html, %(data-clipboard-value-value="#{CGI.escapeHTML(text)}")
  end

  test "indentation survives the coloring" do
    html = render("on:\n  push:\n    branches: [main]\n")

    # Four spaces before `branches`, outside any colored span.
    assert_includes html, %(    <span class="text-voodu-blue">branches</span>)
  end

  # Fail-soft: a highlighter that hides what it cannot parse is worse than one
  # that does not color it. The operator is reading this to find out why their
  # deploy did not fire.
  test "a line the tokeniser does not recognize still renders" do
    html = render("|\n  some block scalar\n>-\n")

    assert_includes html, "some block scalar"
    assert_includes html, "&gt;-"
  end

  test "an empty file renders without raising" do
    assert_nothing_raised { render("") }
  end

  test "list items keep their dash and color the item" do
    html = render("branches:\n  - main\n  - staging\n")

    assert_includes html, %(<span class="text-voodu-green">main</span>)
    assert_includes html, %(<span class="text-voodu-green">staging</span>)
  end

  # `- ` already carries its own trailing space. Adding another rendered every
  # list item as `-  main`, which is not what the file says.
  test "a list item is not indented an extra space" do
    html = render(%(paths:\n  - "app/**"\n))

    assert_not_includes html, %(<span class="text-voodu-muted">- </span> )
  end
end
