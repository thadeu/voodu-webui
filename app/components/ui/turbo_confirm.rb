# frozen_string_literal: true

# Components::UI::TurboConfirm — the singleton DS confirmation dialog that
# backs the global Turbo confirm override (confirm_host_controller). Mounted
# ONCE at the dashboard layout root; hidden until Turbo asks to confirm a
# `data-turbo-confirm` action, at which point the controller fills the
# message and shows it. Confirm/Cancel resolve the promise Turbo awaits.
#
# Visual parity with Components::UI::ConfirmDialog / Modal (same tokens).
class Components::UI::TurboConfirm < Components::Base
  def view_template
    div(data: {controller: "confirm-host"}) do
      div(hidden: true, data: {confirm_host_target: "modal"}) do
        backdrop
        dialog
      end
    end
  end

  private

  def backdrop
    div(
      "aria-hidden": "true",
      data: {action: "click->confirm-host#cancel"},
      class: "fixed inset-0 z-[80] bg-black/55 backdrop-blur-[3px]"
    )
  end

  # `group` + data-theme drives the per-theme coloring (confirm / danger /
  # warn) of the icon + confirm button below, via group-data-[theme=…]
  # variants. The confirm-host controller sets data-theme from the triggering
  # element's data-turbo-confirm-theme before opening.
  def dialog
    div(
      role: "dialog",
      "aria-modal": "true",
      "aria-labelledby": "voodu-turbo-confirm-title",
      data: {confirm_host_target: "dialog", theme: "confirm"},
      class: tokens(
        "group fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 z-[85]",
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

  # Per-theme icon-box colors (confirm=accent, danger=red, warn=amber).
  # Plain string literals (NOT tokens() — that's an instance helper, not
  # available at class-body scope).
  ICON_THEME =
    "group-data-[theme=confirm]:bg-voodu-accent-dim group-data-[theme=confirm]:border-voodu-accent-line group-data-[theme=confirm]:text-voodu-accent-2 " \
    "group-data-[theme=danger]:bg-voodu-red-dim group-data-[theme=danger]:border-voodu-red/40 group-data-[theme=danger]:text-voodu-red " \
    "group-data-[theme=warn]:bg-voodu-amber-dim group-data-[theme=warn]:border-voodu-amber/40 group-data-[theme=warn]:text-voodu-amber"

  # Per-theme confirm-button colors. Amber is light → dark text; the others
  # keep the on-accent (light) text.
  BTN_THEME =
    "group-data-[theme=confirm]:border-voodu-accent-line group-data-[theme=confirm]:bg-voodu-accent group-data-[theme=confirm]:hover:bg-voodu-accent-2 group-data-[theme=confirm]:text-voodu-on-accent " \
    "group-data-[theme=danger]:border-voodu-red/60 group-data-[theme=danger]:bg-voodu-red group-data-[theme=danger]:hover:bg-voodu-red/90 group-data-[theme=danger]:text-voodu-on-accent " \
    "group-data-[theme=warn]:border-voodu-amber/60 group-data-[theme=warn]:bg-voodu-amber group-data-[theme=warn]:hover:bg-voodu-amber/90 group-data-[theme=warn]:text-voodu-bg"

  def header_section
    header(class: "flex items-center gap-2.5 px-4 py-3.5 border-b border-voodu-border bg-voodu-surface") do
      span(class: tokens("inline-flex items-center justify-center w-[26px] h-[26px] shrink-0 border", ICON_THEME)) do
        render Icon::QuestionMarkCircleOutline.new(class: "w-3.5 h-3.5")
      end

      h2(
        id: "voodu-turbo-confirm-title",
        class: "m-0 text-[15px] font-semibold text-voodu-text leading-tight flex-1 min-w-0"
      ) { "Confirm" }

      button(
        type: "button",
        "aria-label": "Close",
        data: {action: "click->confirm-host#cancel"},
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
      ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
    end
  end

  def body_section
    div(class: "px-4 py-4 overflow-auto min-h-0") do
      p(
        data: {confirm_host_target: "message"},
        class: "text-[13px] text-voodu-text-2 leading-relaxed m-0"
      ) { "Are you sure?" }
    end
  end

  def footer_section
    footer(class: "flex items-center gap-2 flex-wrap px-4 py-3 border-t border-voodu-border bg-voodu-bg-2") do
      div(class: "flex-1")

      button(
        type: "button",
        data: {action: "click->confirm-host#cancel"},
        class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
      ) { "Cancel" }

      button(
        type: "button",
        data: {role: "confirm", action: "click->confirm-host#confirm"},
        class: tokens("inline-flex items-center gap-1.5 px-3 h-9 border text-[12.5px] font-medium", BTN_THEME)
      ) do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
        span { "Confirm" }
      end
    end
  end
end
