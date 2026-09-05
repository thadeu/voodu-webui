# frozen_string_literal: true

# A trigger file, highlighted, with a copy button.
#
# ## Why a hand-rolled tokeniser and not a highlighting gem
#
# The YAML shown here is not arbitrary: it is `spec.to_yaml`, re-serialised by
# US from a struct the box already parsed and validated. The grammar that can
# reach this component is keys, nested maps, lists of scalars, and comments —
# and that is small enough to colour honestly in fifty lines.
#
# A gem would highlight anchors, multi-line blocks and tags this input cannot
# contain, in exchange for a dependency on every page of the app. It is the
# right call the day we render a customer's file verbatim; today it would be
# paying for a grammar we do not accept.
#
# LINE-BASED AND FAIL-SOFT. Anything the tokeniser does not recognise is
# rendered as plain text, never dropped and never escaped twice. A highlighter
# that hides a line it cannot parse is worse than one that does not colour it:
# the operator is reading this to find out why their deploy did not fire.
class Components::Deploys::YamlBlock < Components::Base
  # `#` inside a quoted string is not a comment. Matched here rather than
  # split naively, because `apply: {file: "a#b.hcl"}` is legal and losing its
  # tail would show the operator a file name that is not theirs.
  COMMENT = /(?<!\S)#.*\z/
  KEY = /\A(\s*)(-\s+)?([\w.\-\/]+)(:)(.*)\z/
  LIST_ITEM = /\A(\s*)(-\s+)(.*)\z/

  def initialize(text:, path: nil, copy_label: nil)
    @text = text.to_s
    @path = path
    @copy_label = copy_label
  end

  def view_template
    render Components::UI::CodeBlock.new(
      copy_value: @text, label: @copy_label || "Copy #{@path || "this file"}"
    ) do
      @text.split("\n", -1).each_with_index do |line, i|
        plain "\n" if i.positive?
        render_line(line)
      end
    end
  end

  private

  def render_line(line)
    if (m = line.match(COMMENT)) && m.begin(0).zero? || line.strip.start_with?("#")
      return span(class: "text-voodu-muted-2") { line }
    end

    if (m = line.match(KEY))
      indent, dash, key, colon, rest = m.captures

      plain indent
      span(class: "text-voodu-muted") { dash } if dash
      span(class: "text-voodu-blue") { key }
      span(class: "text-voodu-muted") { colon }

      return render_value(rest)
    end

    if (m = line.match(LIST_ITEM))
      indent, dash, rest = m.captures

      plain indent
      span(class: "text-voodu-muted") { dash }

      # No space prepended: `dash` is already "- " with its own trailing space,
      # and adding one rendered every list item as `-  "app/**"`.
      return render_value(rest)
    end

    plain line
  end

  # The value, plus a trailing comment if the line carries one.
  def render_value(rest)
    if (m = rest.match(COMMENT))
      value = rest[0...m.begin(0)]

      scalar(value)

      return span(class: "text-voodu-muted-2") { m[0] }
    end

    scalar(rest)
  end

  # Numbers and booleans read differently from strings, which is the whole
  # reason to colour a config file: `branches: [main]` and `enabled: true` are
  # different kinds of thing and should not look identical.
  def scalar(text)
    return if text.empty?

    stripped = text.strip

    if stripped.empty?
      plain text
    elsif stripped.match?(/\A(true|false|null|~)\z/)
      colored(text, "text-voodu-purple")
    elsif stripped.match?(/\A-?\d+(\.\d+)?\z/)
      colored(text, "text-voodu-amber")
    else
      colored(text, "text-voodu-green")
    end
  end

  # Keeps the original leading whitespace outside the coloured span, so
  # indentation never picks up a colour and copy still reproduces it exactly.
  def colored(text, klass)
    lead = text[/\A\s*/]

    plain lead
    span(class: klass) { text[lead.length..] }
  end
end
