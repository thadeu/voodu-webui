# frozen_string_literal: true

# Components::Pods::EnvCard — pod environment variables, alphabetised.
#
# Header has an inline filter input (Stimulus `kv-filter` controller)
# that hides KvRows whose key OR value doesn't match. No round-trip —
# whole list is in the DOM, filtering is local.
#
# Values containing `***` (the PAT plane redaction marker for
# secrets) render in amber so the operator immediately sees what was
# scrubbed.
#
# All other non-empty values render MASKED by default (bullets).
# The operator opts into seeing a real value via:
#
#   - per-row eye button next to Copy (no extra confirmation)
#   - header eye that reveals ALL — first use opens an inline confirm
#     popover so a misclick doesn't shoulder-surf an entire env block
#
# Mask state is per-session, per-page; nothing is persisted.
class Components::Pods::EnvCard < Components::Base
  # Cap how many bullets we render so a 4kB JWT doesn't draw 4000
  # characters worth of `•` (would dominate the row visually + slow
  # the DOM). 32 is a sweet spot — long enough to look "non-trivial"
  # but bounded.
  MASK_BULLETS_MAX = 32

  def initialize(pod:)
    @pod = pod
  end

  def view_template
    entries = sorted_env

    card = Components::UI::SectionCard.new(title: "Environment · #{entries.size}")
    card.with_action { period_chip(entries.size) }

    render card do
      # Both controllers live on the same wrapper — kv-filter walks
      # rows for the filter input, secret-reveal walks them for the
      # eye toggles. They don't conflict (different target names).
      div(data: { controller: "kv-filter secret-reveal" }, class: "relative") do
        filter_bar(entries.any?)
        rows(entries)
        confirm_popover if entries.any?
      end
    end
  end

  private

  def sorted_env
    h = @pod["env"]
    return [] unless h.is_a?(Hash)

    h.sort_by { |k, _| k.to_s }
  end

  def period_chip(_count)
    # No period selector here — slot left empty for future controls.
  end

  def filter_bar(any_revealable)
    div(class: "flex items-center gap-2 px-3.5 h-9 border-b border-voodu-border bg-voodu-bg-2") do
      render Icon::MagnifyingGlassOutline.new(class: "w-3 h-3 text-voodu-muted shrink-0")
      input(
        type: "search",
        placeholder: "filter keys or values…",
        data: {
          kv_filter_target: "input",
          action: "input->kv-filter#filter"
        },
        class: "flex-1 bg-transparent border-0 outline-none text-[12px] text-voodu-text placeholder:text-voodu-muted-2"
      )

      global_eye_toggle if any_revealable
    end
  end

  # global_eye_toggle — header-level reveal. Default state is
  # "masked" (Eye icon, prompt to show). On reveal it swaps to
  # the slashed-eye + "Hide" tooltip.
  def global_eye_toggle
    button(
      type: "button",
      title: "Show all values",
      "aria-label": "Show all values",
      data: {
        action: "click->secret-reveal#toggleAll",
        secret_reveal_target: "globalBtn"
      },
      class: "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text shrink-0"
    ) do
      # Eye icon (visible when masked); slashed-eye (visible when revealed).
      # Stimulus swaps `hidden` between the two on toggle.
      span(data: { secret_eye: true }) do
        render Icon::EyeOutline.new(class: "w-3.5 h-3.5")
      end
      span(data: { secret_eye_slash: true }, hidden: true) do
        render Icon::EyeSlashOutline.new(class: "w-3.5 h-3.5")
      end
    end
  end

  def rows(entries)
    if entries.empty?
      empty
    else
      div(data: { kv_filter_target: "list" }) do
        entries.each { |k, v| env_row(k, v) }
      end
      empty_match
    end
  end

  def env_row(key, value)
    str = value.to_s
    redacted = str.include?("***")
    revealable = !str.blank? && !redacted
    pair = "#{key}=#{str}"

    div(
      data: {
        kv_filter_target:     "row",
        secret_reveal_target: ("row" if revealable),
        key:                  key.to_s.downcase,
        value:                str.downcase
      }.compact
    ) do
      row_component(key, str, redacted, revealable, pair)
    end
  end

  def row_component(key, str, redacted, revealable, pair)
    row = Components::UI::KvRow.new(key: key, copy: true, copy_value: pair)
    row.with_leading_actions { row_eye_button } if revealable

    render row do
      if str.blank?
        span(class: "text-voodu-muted-2") { "(empty)" }
      elsif redacted
        span(class: "text-voodu-amber") { plain str }
      else
        masked_value(str)
      end
    end
  end

  # masked_value — two siblings inside a wrapper. `mask` is
  # visible by default; `value` is hidden. Stimulus toggles their
  # `hidden` attributes when the eye is clicked. Marking the mask
  # `select-none` keeps the operator from accidentally
  # cmd-C-ing a wall of bullets thinking it's the secret.
  def masked_value(str)
    bullets = "•" * [str.length, MASK_BULLETS_MAX].min

    span do
      span(
        data: { secret_mask: true },
        class: "select-none text-voodu-muted"
      ) { bullets }
      span(
        data: { secret_value: true },
        hidden: true
      ) { plain str }
    end
  end

  def row_eye_button
    button(
      type: "button",
      title: "Show value",
      "aria-label": "Show value",
      data: { action: "click->secret-reveal#toggleOne" },
      class: "inline-flex items-center justify-center w-5 h-5 text-voodu-muted hover:text-voodu-text"
    ) do
      span(data: { secret_eye: true }) do
        render Icon::EyeOutline.new(class: "w-3 h-3")
      end
      span(data: { secret_eye_slash: true }, hidden: true) do
        render Icon::EyeSlashOutline.new(class: "w-3 h-3")
      end
    end
  end

  # confirm_popover — small inline anchored confirm shown the
  # first time the operator clicks the GLOBAL eye. Lightweight
  # vs spawning a full modal for what's a single binary choice.
  # Subsequent reveals in the same view skip this (the controller
  # remembers the operator already committed via confirmedValue).
  def confirm_popover
    div(
      hidden: true,
      data: { secret_reveal_target: "confirm" },
      class: "absolute right-2 top-10 z-30 w-[280px] p-3 border border-voodu-amber/40 bg-voodu-surface-2 shadow-2xl flex flex-col gap-2"
    ) do
      div(class: "flex items-start gap-2") do
        render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5 text-voodu-amber shrink-0 mt-0.5")
        div(class: "text-[12px] text-voodu-text-2 leading-snug") do
          plain "Reveal all environment values? They may contain secrets — anyone shoulder-surfing will see them."
        end
      end
      div(class: "flex items-center gap-2 justify-end") do
        button(
          type: "button",
          data: { action: "click->secret-reveal#cancelReveal" },
          class: "inline-flex items-center justify-center px-2.5 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] hover:bg-voodu-surface-2 hover:text-voodu-text"
        ) { "Cancel" }
        button(
          type: "button",
          data: { action: "click->secret-reveal#confirmReveal" },
          class: "inline-flex items-center gap-1.5 px-2.5 h-7 border border-voodu-amber/60 bg-voodu-amber-dim text-voodu-amber text-[12px] font-medium hover:bg-voodu-amber-dim hover:brightness-110"
        ) do
          render Icon::EyeOutline.new(class: "w-3 h-3")
          span { "Show all" }
        end
      end
    end
  end

  def empty
    div(class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]") { "no environment keys" }
  end

  def empty_match
    div(
      hidden: true,
      data: { kv_filter_target: "empty" },
      class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]"
    ) { "no keys match the filter." }
  end
end
