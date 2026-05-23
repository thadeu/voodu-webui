# frozen_string_literal: true

# Views::Shared::MilestonePlaceholder — the "real content lands in M4"
# stub used by every screen that exists structurally (route + nav
# entry) but doesn't have its functional implementation yet.
#
# Keeps the look + framing consistent across all placeholder pages so
# the operator's mental model is "this section exists, just isn't
# wired" — not "this is broken."
class Views::Shared::MilestonePlaceholder < Components::Base
  def initialize(title:, blurb:, milestone:)
    @title     = title
    @blurb     = blurb
    @milestone = milestone
  end

  def view_template
    div(class: "mx-auto max-w-3xl px-6 py-10") do
      render(Components::UI::Card.new
              .with_header { span(class: "text-sm font-semibold text-voodu-muted") { @milestone }}) do
        div(class: "flex flex-col gap-3 py-2") do
          h1(class: "text-xl font-semibold text-voodu-text") { @title }
          p(class: "text-voodu-text-2") { @blurb }
          div(class: "pt-2") do
            render Components::UI::Badge.new(variant: :neutral) { "M4 will fill this view" }
          end
        end
      end
    end
  end
end
