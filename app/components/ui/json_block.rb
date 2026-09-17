# frozen_string_literal: true

# Components::UI::JsonBlock — a JSON document, colored, with a copy button.
#
# ## Rendered from the PARSED VALUE, never from text
#
# The YAML highlighter beside this tokenises a string with regexes, and it has
# to: YAML has no structural form we hold. JSON does — we already have the Hash
# — so this walks it and emits spans directly.
#
# That difference matters for correctness, not elegance. A regex over JSON text
# has to decide whether a `{` is punctuation or a character inside a string,
# and a webhook payload is full of strings containing braces, quotes and
# newlines — commit messages, diffs, URLs. Walking the value cannot get that
# wrong, because a String is a String before it is ever printed.
#
# ## What it does NOT do
#
# It does not truncate and it does not fold. The card scrolls, and a payload is
# evidence — the reader is here because something disagreed with what they
# expected, and hiding part of it is how the disagreement stays unresolved.
class Components::UI::JsonBlock < Components::Base
  # Two spaces, matching `JSON.pretty_generate` — the copy button hands back
  # that exact string, and a screen indented differently from the clipboard is
  # a screen somebody will file a bug about.
  INDENT = "  "

  def initialize(value:, label: "Copy", max_height: nil)
    @value = value
    @label = label
    @max_height = max_height
  end

  def view_template
    render Components::UI::CodeBlock.new(
      copy_value: JSON.pretty_generate(@value), label: @label, max_height: @max_height
    ) { node(@value, 0) }
  end

  private

  def node(value, depth)
    case value
    when Hash then object(value, depth)
    when Array then array(value, depth)
    else scalar(value)
    end
  end

  def object(hash, depth)
    return punct("{}") if hash.empty?

    punct("{")

    hash.each_with_index do |(key, value), i|
      punct(",") if i.positive?
      newline(depth + 1)

      span(class: "text-voodu-blue") { key.to_s.to_json }
      punct(": ")

      node(value, depth + 1)
    end

    newline(depth)
    punct("}")
  end

  def array(items, depth)
    return punct("[]") if items.empty?

    punct("[")

    items.each_with_index do |item, i|
      punct(",") if i.positive?
      newline(depth + 1)

      node(item, depth + 1)
    end

    newline(depth)
    punct("]")
  end

  # Colors by TYPE, which is the whole reason to highlight a payload: `"1357"`
  # and `1357` look identical in gray and mean different things to whatever
  # reads them next.
  def scalar(value)
    case value
    when String then span(class: "text-voodu-green") { value.to_json }
    when Numeric then span(class: "text-voodu-amber") { value.to_json }
    when true, false, nil then span(class: "text-voodu-purple") { value.to_json }
    else span(class: "text-voodu-text-2") { value.to_s }
    end
  end

  def punct(text)
    span(class: "text-voodu-muted") { text }
  end

  def newline(depth)
    plain "\n#{INDENT * depth}"
  end
end
