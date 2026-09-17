# frozen_string_literal: true

# Who caused a push: the avatar, with the login on hover.
#
# AVATAR AND NOT A NAME IN TEXT. In a list of deploys the person is the fastest
# thing to recognize and the least useful to read — you scan for "one of mine"
# or "not one of mine", and a face answers that in a glance where a login
# costs a word of column width per row.
#
# WHEN NOBODY IS NAMED it draws a muted silhouette rather than nothing. The
# earlier version rendered an empty cell, which left the column ragged — half
# the rows with a circle and half without, reading as rows that failed to load
# rather than rows nobody signed.
#
# The silhouette says UNKNOWN, not "a person". A `ping`, or a delivery whose
# signature we refused, genuinely has no sender — so the tooltip and the label
# say "Unknown sender" rather than inventing a name for the shape.
class Components::Deploys::Sender < Components::Base
  # `linked: false` for a sender drawn INSIDE a link — which every table row
  # is.
  #
  # Nested anchors are invalid HTML, and they do not fail quietly: the parser
  # closes the outer `<a>` at the inner one, so every cell after the avatar
  # spills out of the row's flex container. The row stops being a row, and only
  # the rows that HAVE a sender break — which reads as a styling bug and is a
  # markup one.
  def initialize(login:, avatar: nil, url: nil, size: :xs, linked: true)
    @login = login.to_s
    @avatar = avatar
    @url = url
    @size = size
    @linked = linked
  end

  def view_template
    div(class: "relative group/sender shrink-0") do
      if @login.blank?
        unknown
      else
        link? ? linked : avatar
      end

      render Components::UI::Tooltip.new(label: @login.presence || "Unknown sender", group: "sender")
    end
  end

  private

  def link? = @linked && @url.present?

  # A link out to GitHub when we have one, plain otherwise. `noopener` because
  # this href comes from a payload — verified as ours, but written by somebody
  # else's server.
  def linked
    a(href: @url, target: "_blank", rel: "noopener noreferrer",
      "aria-label": "#{@login} on GitHub", class: "block no-underline") { avatar }
  end

  def avatar
    render Components::UI::Avatar.new(url: @avatar, name: @login, size: @size)
  end

  # The same circle as a real avatar — same diameter, same rounding — so the
  # column lines up whether or not anybody signed the push. Muted and outlined
  # rather than filled: it must not compete with the faces beside it.
  # The glyph sized by CLASS, not by inline style. PhlexIcons ships each icon
  # with `size-6`, and a style attribute only wins that fight by specificity —
  # a rule that holds until somebody adds `!important` or the library changes
  # its default. Passing `class:` replaces theirs outright, which is what every
  # other icon in this codebase does.
  GLYPH = {xs: "w-3 h-3", sm: "w-4 h-4", md: "w-5 h-5"}.freeze

  def unknown
    px = Components::UI::Avatar::SIZES.fetch(@size, 20)

    div(
      style: "width: #{px}px; height: #{px}px;",
      class: "rounded-full shrink-0 flex items-center justify-center " \
             "border border-voodu-border-2 text-voodu-muted-2",
      "aria-label": "Unknown sender"
    ) do
      render Icon::UserSolid.new(class: GLYPH.fetch(@size, "w-3 h-3"))
    end
  end
end
