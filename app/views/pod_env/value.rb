# frozen_string_literal: true

# One revealed value — the ONLY place in this application a config or
# environment value is rendered.
#
# It exists because revealing is a REQUEST, not a toggle. Until this view runs,
# the value has not been in the page: not in a hidden span, not in a data
# attribute, not in a copy button's payload. A page that ships every value and
# hides them in CSS is a page where one script or one "inspect element" reads
# the lot, and where the mask is theatre over something already handed out.
#
# TWO SHAPES, one value:
#
#   :inline — a list row. Text plus a copy button, which only now has anything
#             to copy.
#   :field  — the drawer. An editable textarea, because the reason to look at
#             a value there is usually to change it.
class Views::PodEnv::Value < Views::Base
  def initialize(key:, value:, pod_name: nil, variant: :inline, error: nil)
    @key = key
    @value = value
    @pod_name = pod_name
    @variant = variant
    @error = error
  end

  # The frame is named per KEY. A single shared frame would be a page where
  # revealing one variable also swaps in the one you looked at before.
  def self.frame_id(key) = "pod-env-value-#{key}"

  def view_template
    # data-turbo-permanent is repeated here, and it is NOT what protects a
    # revealed value — the card's own frame is (see EnvCard#value_frame).
    #
    # Turbo's FrameRenderer replaces a frame's CONTENTS and never copies the
    # response frame's attributes onto the live element, so this attribute is
    # inert on the page. It is kept for the case where this view is rendered
    # into a frame that does not already exist — a fresh drawer body — and so
    # that reading either file does not suggest the other forgot it.
    turbo_frame_tag(self.class.frame_id(@key), data: {turbo_permanent: true}) do
      if @error
        failure
      elsif field?
        field
      else
        inline
      end
    end
  end

  private

  def field? = @variant == :field

  # TRUNCATED EVEN AFTER REVEALING, and the copy button carries the whole
  # thing. Revealing answers "which value is this" — the first characters of a
  # connection string or a token settle that. It does not have to answer
  # "recite the secret", and a full 200-character token on screen is one
  # shoulder, one screen-share or one screenshot away from being somewhere
  # else.
  #
  # No `title` attribute either: a tooltip on hover would put the whole value
  # back, one mouse position away from the thing this avoids.
  #
  # ONLY HERE. The drawer's variant must never truncate — it is an editable
  # field, and a shortened value in it would be saved as the new value.
  TRUNCATE_AT = 48

  def inline
    div(class: "flex items-center gap-2 min-w-0") do
      # ONE LINE, always. `truncate` (overflow-hidden + ellipsis + nowrap) and
      # not `break-all`, which wrapped 48 characters onto three lines and made
      # a revealed row three times the height of its neighbours — the list
      # jumped every time somebody clicked an eye.
      #
      # Two cuts stack here and they answer different things. The Ruby one is
      # the SECURITY bound: the tail never reaches the page. The CSS one is
      # the LAYOUT bound: whatever survives still has to fit the column. Either
      # can bite first, and the row looks the same either way.
      span(class: "font-voodu-mono text-[12px] text-voodu-text min-w-0 flex-1 truncate") do
        display
      end

      truncation_note if truncated?

      # The copy button appears only NOW, and it is the ONLY way to the whole
      # value. Before the reveal there was nothing to put in it — which was
      # the point.
      render Components::UI::CopyButton.new(
        value: @value.to_s, label: "Copy #{@key} in full", announce_value: false
      )
    end
  end

  def display
    return "(empty)" if @value.to_s.empty?

    truncated? ? "#{@value.to_s[0, TRUNCATE_AT]}…" : @value.to_s
  end

  def truncated? = @value.to_s.length > TRUNCATE_AT

  # Says the value is cut, so nobody reads a shortened connection string as the
  # real one and types it into a config file by hand.
  #
  # Short, because it competes for the same row as the value it annotates —
  # "· copy for all" was six words explaining a button sitting right beside it.
  # The button's own tooltip carries that now.
  def truncation_note
    span(class: "text-[10.5px] text-voodu-muted shrink-0 whitespace-nowrap") do
      "+#{@value.to_s.length - TRUNCATE_AT}"
    end
  end

  def field
    div(class: "flex flex-col gap-1.5") do
      textarea(
        name: "value", rows: "3", spellcheck: "false", class: textarea_class
      ) { @value.to_s }

      span(class: "text-[11px] text-voodu-muted") { "Revealed. Editing replaces it." }
    end
  end

  def failure
    return inline_failure unless field?

    div(class: "flex flex-col gap-1.5") do
      # Kept editable: not being able to SEE the current value is no reason to
      # be unable to SET one.
      textarea(
        name: "value", rows: "3", spellcheck: "false", placeholder: "new value",
        class: textarea_class
      ) { "" }

      span(class: "text-[11.5px] text-voodu-red") { @error.to_s }
    end
  end

  def inline_failure
    span(class: "text-[11.5px] text-voodu-red") { @error.to_s }
  end

  def textarea_class
    "w-full px-3 py-2 bg-voodu-surface-2 border border-voodu-border text-voodu-text " \
      "font-voodu-mono text-[12.5px] outline-none break-all placeholder:text-voodu-muted-2 " \
      "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line"
  end
end
