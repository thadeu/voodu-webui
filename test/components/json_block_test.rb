# frozen_string_literal: true

require "test_helper"

# A JSON payload, colored, rendered FROM THE PARSED VALUE.
#
# The YAML highlighter beside it tokenises text with regexes and has to. JSON
# does not: we already hold the Hash. Most of this file is the difference that
# makes — a webhook payload is full of strings containing braces, quotes and
# newlines, and a regex has to guess which are punctuation. Walking the value
# cannot guess wrong.
class JsonBlockTest < ActiveSupport::TestCase
  def render(value, **opts)
    ApplicationController.render(
      Components::UI::JsonBlock.new(value: value, **opts), layout: false
    )
  end

  # The rendered CODE only. Stripping tags from the whole block would also
  # sweep up the copy button's markup, and the point of this helper is to
  # compare what a reader SEES against what the clipboard gets.
  def text(html)
    inner = html[%r{<code>(.*)</code>}m, 1].to_s

    CGI.unescapeHTML(inner.gsub(/<[^>]+>/, ""))
  end

  # Quotes are HTML-escaped in the markup, which is correct — asserting with
  # raw quotes tests the test's escaping rather than the component.
  def span_for(color, literal)
    %(<span class="text-voodu-#{color}">#{CGI.escapeHTML(literal)}</span>)
  end

  test "types are told apart" do
    html = render({"name" => "web", "port" => 3000, "enabled" => true, "note" => nil})

    assert_includes html, span_for("blue", %("name"))
    assert_includes html, span_for("green", %("web"))
    assert_includes html, span_for("amber", "3000")
    assert_includes html, span_for("purple", "true")
    assert_includes html, span_for("purple", "null")
  end

  # `"1357"` and `1357` look identical in gray and mean different things to
  # whatever reads them next — that is the whole reason to color a payload.
  test "a numeric string is not colored as a number" do
    html = render({"id" => 1357, "node_id" => "1357"})

    assert_includes html, span_for("amber", "1357")
    assert_includes html, span_for("green", %("1357"))
  end

  # THE REASON THIS WALKS THE VALUE. A commit message is arbitrary text, and a
  # regex over the printed form has to decide whether each brace is punctuation
  # or content.
  test "a string full of punctuation does not confuse the coloring" do
    message = %({"not": "json"} and a \\"quote\\" and a newline)
    html = render({"message" => message})

    # The whole string arrives as ONE green scalar, braces and all.
    assert_includes html, span_for("green", message.to_json)
  end

  test "nesting and arrays render" do
    html = render({"repo" => {"tags" => ["a", "b"], "owner" => {"login" => "thadeu"}}})
    flat = text(html)

    assert_includes flat, %("tags")
    assert_includes flat, %("a")
    assert_includes flat, %("login")
  end

  test "empty containers render compactly" do
    flat = text(render({"a" => {}, "b" => []}))

    assert_includes flat, "{}"
    assert_includes flat, "[]"
  end

  # THE PROPERTY THAT MATTERS MOST. A copy button that hands back something
  # other than what is on screen is a trap: somebody pastes it into a bug
  # report and the two do not match.
  test "the text on screen is exactly what the copy button carries" do
    value = {"ref" => "refs/heads/main", "count" => 2, "ok" => false, "list" => [1, "two"]}
    html = render(value)

    assert_equal JSON.pretty_generate(value), text(html)
    assert_includes html, %(data-clipboard-value-value="#{CGI.escapeHTML(JSON.pretty_generate(value))}")
  end

  test "an empty payload renders without raising" do
    assert_nothing_raised { render({}) }
  end

  # A real GitHub push payload, in the shape that actually arrives — nested
  # objects, arrays of objects, a commit message with punctuation, ids that are
  # numbers beside ids that are strings.
  test "a real push payload survives the round trip intact" do
    payload = {
      "ref" => "refs/heads/main",
      "after" => "1a8bfe2b11d6a3d42c701b7b6f45f343a56417b2",
      "repository" => {
        "id" => 1_357_172_984,
        "node_id" => "R_kgDOUOTQ-A",
        "full_name" => "thadeu/contagorda",
        "private" => false,
        "owner" => {"name" => "thadeu", "email" => "x@example.com"}
      },
      "commits" => [
        {"message" => "fix: handle {braces} and \"quotes\"", "distinct" => true},
        {"message" => "chore: bump", "distinct" => false}
      ]
    }

    html = render(payload)

    assert_equal JSON.pretty_generate(payload), text(html)

    # And the two id kinds stayed apart.
    assert_includes html, span_for("amber", "1357172984")
    assert_includes html, span_for("green", %("R_kgDOUOTQ-A"))
  end
end
