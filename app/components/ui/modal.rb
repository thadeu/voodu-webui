# frozen_string_literal: true

# Components::UI::Modal — generic centered dialog with backdrop.
#
# DS primitive: any feature that needs a modal (Add server, Edit
# server, future "confirm destructive action", etc.) renders this
# component with slots, instead of re-rolling its own backdrop + scroll
# lock + ESC handling.
#
# Slots (mirrors Components::UI::Card):
#
#   render Components::UI::Modal.new(title: "Add server",
#                                    subtitle: "Connect a Docker host",
#                                    icon: :PlusOutline,
#                                    close_to: helpers.islands_path)
#     .with_footer { div { "Cancel  · Add server" } } do
#       form { ... }
#     end
#
# The component renders TWO elements (backdrop + dialog) as siblings
# inside a single wrapper `<div data-controller="modal">` so the
# Stimulus modal_controller can manage them together (ESC, click on
# backdrop, scroll-lock on body, initial focus).
#
# Props
#
#   title:     — H2 displayed in the header. Required.
#   subtitle:  — small line under the title. Optional.
#   icon:      — icon symbol (PhlexIcons::Hero const name) shown in
#                the header avatar. Optional.
#   size:      — :sm (400) | :md (520) | :lg (720). Default :md.
#                (Always capped by `100vw - 24px` so it never exceeds
#                the viewport on mobile.)
#   blur:      — backdrop CSS `backdrop-blur`. Default true.
#   closable:  — whether the X button + ESC + click-out close the
#                modal. Default true. Set false during in-flight
#                async operations.
#   close_to:  — URL the X button + Cancel navigate to. The
#                modal is currently a FULL PAGE rendering (no
#                client-side overlay state), so closing = navigating
#                away. For a future overlay-mode (open in-place
#                without a route change), Stimulus will toggle
#                `hidden` instead — see modal_controller.
class Components::UI::Modal < Components::Base
  SIZES = {
    sm: "w-[min(400px,calc(100vw-24px))]",
    md: "w-[min(520px,calc(100vw-24px))]",
    lg: "w-[min(720px,calc(100vw-24px))]"
  }.freeze

  def initialize(title:, subtitle: nil, icon: nil, size: :md,
                 blur: true, closable: true, close_to: nil)
    @title    = title
    @subtitle = subtitle
    @icon     = icon
    @size     = size
    @blur     = blur
    @closable = closable
    @close_to = close_to

    @footer_block = nil
  end

  def with_footer(&block)
    @footer_block = block
    self
  end

  def view_template(&body)
    div(data: { controller: "modal", modal_closable_value: @closable.to_s }) do
      backdrop
      dialog(&body)
    end
  end

  private

  # backdrop — semi-opaque overlay covering the viewport. Clicking
  # it triggers `modal#close` (which respects `closable_value`).
  def backdrop
    div(
      "aria-hidden": "true",
      data: { action: "click->modal#backdropClick", modal_target: "backdrop" },
      class: tokens(
        "fixed inset-0 z-[65] bg-black/55",
        ("backdrop-blur-[3px]" if @blur)
      )
    )
  end

  # dialog — the actual modal card. Centered via fixed +
  # translate trick (no flex parent needed). z-70 > backdrop's 65.
  def dialog(&body)
    div(
      role: "dialog",
      "aria-modal": "true",
      "aria-labelledby": "voodu-modal-title",
      data: { modal_target: "dialog" },
      class: tokens(
        "fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 z-[70]",
        SIZES.fetch(@size),
        "max-h-[calc(100vh-48px)]",
        "flex flex-col",
        "bg-voodu-surface-2 border border-voodu-border-2",
        # Lift visibly above the blurred backdrop. Two shadows so the
        # outer cast covers the wide diffuse zone and the inner one
        # crisps the edge against the darker surface beneath.
        "shadow-[0_28px_56px_rgba(0,0,0,0.65),0_4px_12px_rgba(0,0,0,0.4)]"
      )
    ) do
      header_section
      div(class: "flex flex-col overflow-auto min-h-0", &body)
      footer_section if @footer_block
    end
  end

  def header_section
    header(
      class: "flex items-center gap-2.5 px-4 py-3.5 border-b border-voodu-border bg-voodu-surface"
    ) do
      if @icon
        span(
          class: "inline-flex items-center justify-center w-[26px] h-[26px] bg-voodu-accent-dim border border-voodu-accent-line text-voodu-accent-2 shrink-0"
        ) do
          render Icon.const_get(@icon).new(class: "w-3.5 h-3.5")
        end
      end

      div(class: "min-w-0 flex-1") do
        h2(
          id: "voodu-modal-title",
          class: "m-0 text-[15px] font-semibold text-voodu-text leading-tight"
        ) { @title }

        if @subtitle
          div(class: "text-[11.5px] text-voodu-muted mt-0.5") { @subtitle }
        end
      end

      close_button if @closable
    end
  end

  # close_button — the X. When `close_to` is set, it's an anchor
  # (full-page navigation, the M-1 mode). When unset, it's a button
  # that fires `modal#close` — Stimulus toggles `hidden` so the
  # overlay can come back without a re-render (M-2 overlay mode).
  def close_button
    if @close_to
      a(
        href: @close_to,
        "aria-label": "Close",
        class: close_btn_classes
      ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
    else
      button(
        type: "button",
        "aria-label": "Close",
        data: { action: "click->modal#close" },
        class: close_btn_classes
      ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
    end
  end

  def close_btn_classes
    "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
  end

  def footer_section
    footer(
      class: "flex items-center gap-2 flex-wrap px-4 py-3 border-t border-voodu-border bg-voodu-bg-2"
    ) { @footer_block.call }
  end
end
