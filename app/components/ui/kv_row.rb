# frozen_string_literal: true

# Components::UI::KvRow — one labelled row inside a SectionCard.
#
# Three columns:
#
#   ┌──────────────────────┬──────────────────────────┬──────────┐
#   │ key (mono, muted)    │ value (mono, text)       │ [copy?]  │
#   └──────────────────────┴──────────────────────────┴──────────┘
#
# Bottom border under each row gives the table look the inspiration
# uses for Spec/Network/Env/Labels cards.
#
# Pass `copy:` to render a Components::UI::CopyButton in the right
# slot — the value is `copy_value` (string). Set `mono: false` if the
# value isn't code-like (rare).
#
# `dim: true` mutes the value column (for "never" / "(empty)" states).
class Components::UI::KvRow < Components::Base
  def initialize(key:, mono: true, dim: false, copy: false, copy_value: nil)
    @key = key
    @mono = mono
    @dim = dim
    @copy = copy
    @copy_value = copy_value
    @leading_actions_block = nil
  end

  # with_leading_actions — slot for buttons rendered LEFT of the
  # CopyButton in the actions column. Used by EnvCard to inject the
  # per-row eye toggle (show/hide secret) alongside Copy without
  # forking the row layout.
  def with_leading_actions(&block)
    @leading_actions_block = block
    self
  end

  def view_template(&)
    div(
      class: "grid items-baseline gap-3.5 px-3.5 py-2 border-b border-voodu-border text-[12.5px] last:border-b-0",
      style: "grid-template-columns: minmax(160px, 220px) 1fr auto;"
    ) do
      div(class: "font-voodu-mono text-[11.5px] text-voodu-muted break-all min-w-0") { @key }
      div(
        class: tokens(
          @mono ? "font-voodu-mono" : "font-voodu-sans",
          @dim ? "text-voodu-muted-2" : "text-voodu-text",
          "break-all min-w-0"
        )
      ) { yield if block_given? }
      div(class: "min-w-[22px] flex items-center justify-end gap-1") do
        @leading_actions_block&.call
        render Components::UI::CopyButton.new(value: @copy_value || "", label: "Copy #{@key}") if @copy && @copy_value
      end
    end
  end
end
