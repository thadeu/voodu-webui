# frozen_string_literal: true

# Components::UI::ConfirmDialog — the confirmation MODAL on its own
# (backdrop + dialog + Cancel/Confirm), driven by the `confirmable`
# Stimulus controller via its `modal` / `dialog` targets and
# confirmable#cancel / confirmable#confirm actions.
#
# Two ways to use it:
#   1. Via Components::UI::Confirmable (form + trigger + this) — the
#      common "wrap a destructive action" case.
#   2. Standalone inside an EXISTING form you wire yourself: put
#      data-controller="confirmable" + data-confirmable-target="form" +
#      data-action="submit->confirmable#prompt" on that form, then render
#      this dialog inside it. Lets a big form (e.g. the dashboard builder)
#      gate its own submit behind the same DS confirm instead of the
#      native window.confirm.
#
# Visual parity with Components::UI::Modal — same tokens, so a restyle of
# either keeps them in lock-step.
class Components::UI::ConfirmDialog < Components::Base
  def initialize(title:, message:, confirm_label: "Confirm", cancel_label: "Cancel",
    danger: false, icon: nil)
    @title = title
    @message = message
    @confirm_label = confirm_label
    @cancel_label = cancel_label
    @danger = danger
    @icon = icon || (danger ? :ExclamationTriangleOutline : :CheckOutline)
  end

  def view_template
    div(hidden: true, data: {confirmable_target: "modal"}) do
      backdrop
      dialog
    end
  end

  private

  def backdrop
    div(
      "aria-hidden": "true",
      data: {action: "click->confirmable#cancel"},
      class: "fixed inset-0 z-[65] bg-black/55 backdrop-blur-[3px]"
    )
  end

  def dialog
    div(
      role: "dialog",
      "aria-modal": "true",
      "aria-labelledby": "voodu-confirmable-title",
      data: {confirmable_target: "dialog"},
      class: tokens(
        "fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 z-[70]",
        "w-[min(420px,calc(100vw-24px))] max-h-[calc(100vh-48px)]",
        "flex flex-col",
        "bg-voodu-surface-2 border border-voodu-border-2",
        "shadow-[0_28px_56px_rgba(0,0,0,0.65),0_4px_12px_rgba(0,0,0,0.4)]"
      )
    ) do
      header_section
      body_section
      footer_section
    end
  end

  def header_section
    header(
      class: "flex items-center gap-2.5 px-4 py-3.5 border-b border-voodu-border bg-voodu-surface"
    ) do
      span(
        class: tokens(
          "inline-flex items-center justify-center w-[26px] h-[26px] shrink-0 border",
          @danger ? "bg-voodu-red-dim border-voodu-red/40 text-voodu-red"
                  : "bg-voodu-accent-dim border-voodu-accent-line text-voodu-accent-2"
        )
      ) do
        render Icon.const_get(@icon).new(class: "w-3.5 h-3.5")
      end

      h2(
        id: "voodu-confirmable-title",
        class: "m-0 text-[15px] font-semibold text-voodu-text leading-tight flex-1 min-w-0"
      ) { @title }

      button(
        type: "button",
        "aria-label": "Close",
        data: {action: "click->confirmable#cancel"},
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
      ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
    end
  end

  def body_section
    div(class: "px-4 py-4 overflow-auto min-h-0") do
      p(class: "text-[13px] text-voodu-text-2 leading-relaxed m-0") { @message }
    end
  end

  def footer_section
    footer(
      class: "flex items-center gap-2 flex-wrap px-4 py-3 border-t border-voodu-border bg-voodu-bg-2"
    ) do
      div(class: "flex-1")

      button(
        type: "button",
        data: {action: "click->confirmable#cancel"},
        class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
      ) { @cancel_label }

      button(
        type: "button",
        data: {action: "click->confirmable#confirm"},
        class: tokens(
          "inline-flex items-center gap-1.5 px-3 h-9 border text-voodu-on-accent text-[12.5px] font-medium",
          @danger ? "border-voodu-red/60 bg-voodu-red hover:bg-voodu-red/90"
                  : "border-voodu-accent-line bg-voodu-accent hover:bg-voodu-accent-2"
        )
      ) do
        render Icon.const_get(@icon).new(class: "w-3.5 h-3.5")
        span { @confirm_label }
      end
    end
  end
end
