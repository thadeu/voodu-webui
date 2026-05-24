# frozen_string_literal: true

# Components::UI::Drawer — right-side slide-in panel that hosts a
# secondary surface (logs viewer, pod detail, etc.) without a full
# page navigation.
#
# DS primitive: any "I'm reading X, peek at Y, come back" interaction
# uses this. The Metrics page uses it for the Logs + Open pod actions
# so the operator can sample data without losing chart context.
#
# Key visual choices:
#   - **No backdrop blur** — page behind stays readable. The drawer
#     is a peek, not a modal. But scroll IS locked on
#     html/body so the page underneath doesn't shift while the
#     operator is reading.
#   - **Right-anchored, configurable initial width (40vw default),
#     clamped on resize by min_width on the left and a viewport-aware
#     max on the right** — follows the inspiration's secondary-surface
#     convention.
#   - **Resizable** — left edge has a draggable handle; the width the
#     operator settles on is persisted in localStorage and re-applied
#     to every drawer instance.
#   - **Lazy fetch** — body content is loaded on first open via
#     fetch(), then injected with innerHTML. Stimulus auto-connects
#     sub-controllers in the injected fragment (log-stream SSE,
#     copy buttons, etc.) so the drawer's contents behave like
#     a "real" rendered page.
#
# Usage
#
#   render(Components::UI::Drawer.new(
#     title:        "Logs · #{name}",
#     src:          "#{helpers.pod_logs_path(name: name)}?embed=1",
#     open_url:     helpers.pod_logs_path(name: name),
#     width:        "40vw",
#     min_width:    "320px",
#     trigger_attrs: { class: btn_secondary_classes }
#   )) do
#     render Icon::DocumentTextOutline.new(class: "w-3.5 h-3.5")
#     span { "Logs" }
#   end
#
# Cmd-click / middle-click on the trigger still opens in a new tab
# (the anchor's native `href` handles it) — Stimulus only intercepts
# plain left-click.
class Components::UI::Drawer < Components::Base
  def initialize(title:, src:, open_url:,
                 trigger_attrs: {},
                 width:     "40vw",
                 min_width: "320px",
                 resizable: true)
    @title         = title
    @src           = src
    @open_url      = open_url
    @width         = width
    @min_width     = min_width
    @resizable     = resizable
    @trigger_attrs = trigger_attrs
  end

  def view_template(&trigger_body)
    div(
      class: "contents",
      data: {
        controller: "drawer",
        drawer_src_value:       @src,
        drawer_min_width_value: @min_width,
        drawer_resizable_value: @resizable.to_s
      }
    ) do
      render_trigger(&trigger_body)
      render_panel
    end
  end

  private

  # render_trigger — anchor (NOT button) so cmd-click / middle-click
  # still gets browser-native "open in new tab" behaviour. The
  # Stimulus action only fires on plain left-click.
  def render_trigger(&trigger_body)
    a(
      href: @open_url,
      data: { action: "click->drawer#open" },
      **@trigger_attrs,
      &trigger_body
    )
  end

  def render_panel
    aside(
      data: { drawer_target: "panel" },
      role: "dialog",
      "aria-modal": "false",
      "aria-labelledby": panel_title_id,
      # Inline `width` so the resize handle can mutate it directly
      # without fighting Tailwind classes. `max-width` from a class
      # caps the upper bound on huge monitors.
      style: "width: #{@width};",
      class: tokens(
        "fixed top-0 right-0 h-screen z-[60]",
        # On mobile the inline width is overridden by w-full (max
        # width helpful with the constraint that 40vw on a 360px
        # screen is too narrow to be useful).
        "max-w-[min(100vw,1200px)]",
        "flex flex-col",
        "bg-voodu-bg-2 border-l border-voodu-border",
        "shadow-[-12px_0_32px_rgba(0,0,0,0.55)]",
        # Slide animation. Start off-screen; controller toggles the
        # `data-open` attribute via `prompt -> #open`.
        "translate-x-full transition-transform duration-200 ease-out",
        "data-[open]:translate-x-0"
      ),
      inert: true
    ) do
      resize_handle if @resizable
      panel_header
      panel_body
    end
  end

  # resize_handle — 5px-wide grab zone on the LEFT edge of the
  # drawer. Pointer-down enters resize mode (controller takes over
  # cursor + selection on the body); pointer-move drags; pointer-up
  # persists the new width to localStorage.
  #
  # Wider hit area than visual stroke so the cursor target is
  # forgiving — the visible affordance is the 1px border-l on the
  # panel itself + cursor: col-resize on this strip.
  def resize_handle
    div(
      data: {
        drawer_target: "handle",
        action:        "pointerdown->drawer#startResize"
      },
      aria: { hidden: "true" },
      title: "Drag to resize",
      class: "absolute top-0 left-0 bottom-0 w-1.5 -ml-1 cursor-col-resize hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-[5] touch-none"
    )
  end

  def panel_header
    header(
      class: "flex items-center gap-2 px-4 h-12 border-b border-voodu-border bg-voodu-surface shrink-0"
    ) do
      h2(
        id: panel_title_id,
        class: "m-0 text-[13px] font-semibold text-voodu-text truncate flex-1 min-w-0"
      ) { @title }

      open_in_tab_link
      close_button
    end
  end

  # open_in_tab_link — explicit "send me to the full page" button.
  # Same tab (no _blank) — operator wanted to keep their flow on the
  # current tab; cmd-click on the trigger still opens in a new tab
  # for the new-tab case, so the two affordances complement.
  def open_in_tab_link
    a(
      href: @open_url,
      title: "Open as full page",
      "aria-label": "Open as full page",
      class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
    ) { render Icon::ArrowTopRightOnSquareOutline.new(class: "w-3.5 h-3.5") }
  end

  def close_button
    button(
      type: "button",
      title: "Close",
      "aria-label": "Close",
      data: { action: "click->drawer#close" },
      class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
    ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
  end

  def panel_body
    div(
      data: { drawer_target: "body" },
      class: "relative flex-1 overflow-auto bg-voodu-bg"
    ) do
      div(class: "h-full flex items-center justify-center text-voodu-muted text-[12px]") do
        plain "loading…"
      end
    end
  end

  def panel_title_id
    "drawer-title-#{object_id}"
  end
end
