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
#     src:          "#{pod_logs_path(name: name)}?embed=1",
#     open_url:     pod_logs_path(name: name),
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
  # show_full_page_link — whether to render the "open as full page"
  # icon button in the panel header. True for content drawers (Logs,
  # Pod detail) where the full page is meaningful; false for
  # settings/tool drawers that have no standalone page equivalent.
  #
  # storage_key — localStorage bucket the resize handle reads/writes.
  # Defaults to the SHARED key so Logs + Pod drawers remember the
  # operator's chosen width together (same content style = same
  # natural width). Pass a unique key (e.g. "voodu:drawer-width:settings")
  # for drawers with a fundamentally different content shape — a
  # compact settings card grid shouldn't inherit the 60vw width an
  # operator set for the logs viewer.
  # id — stable identifier for the Turbo "permanent" wrapping. When
  # this drawer's host frame is re-rendered (e.g. StateSyncIslandJob's
  # state_tick reloading the pod show frame), Turbo matches the
  # before/after nodes by id and KEEPS the current one — preserving
  # the Stimulus controller instance, the `data-open` state, the
  # already-fetched body content, and any focus. Without it the
  # frame reload would clobber the drawer mid-read.
  #
  # Default derives a deterministic short hash from `src` so two
  # different drawers in the same frame get different ids automatically.
  # Pass an explicit `id:` for readability / debuggability when the
  # call site has a natural identifier ("drawer-logs-#{pod_name}").
  # max_width — upper bound the operator can drag the panel to (and
  # the CSS `max-width` ceiling, which applies even without dragging).
  # Default `min(100vw, 1200px)` matches the previous hard-coded cap:
  # at most the full viewport, at most 1200px on huge monitors. Pass
  # a larger value (e.g. "85vw") for content-heavy drawers like the
  # logs viewer where the operator routinely wants a wider tail.
  #
  # Accepts any CSS length expression (`"85vw"`, `"1400px"`,
  # `"min(100vw, 1600px)"`). Used both in the inline style of the
  # panel and in the resize handle's clamp logic.
  def initialize(title:, src:, open_url:,
    id: nil,
    trigger_attrs: {},
    width: "40vw",
    min_width: "320px",
    max_width: "min(100vw, 1200px)",
    resizable: true,
    show_full_page_link: true,
    permanent: true,
    custom_trigger: false,
    storage_key: "voodu:drawer-width")
    @title = title
    @src = src
    @open_url = open_url
    @width = width
    @min_width = min_width
    @max_width = max_width
    @resizable = resizable
    @trigger_attrs = trigger_attrs
    @show_full_page_link = show_full_page_link
    @permanent = permanent
    @custom_trigger = custom_trigger
    @storage_key = storage_key
    @id = id || "drawer-#{Digest::SHA1.hexdigest(src.to_s)[0, 12]}"
  end

  def view_template(&trigger_body)
    # `data-turbo-permanent` + stable id preserves THIS node across
    # frame reloads (the open state lives client-side). Needed when the
    # drawer's host frame re-renders (e.g. pod-show state_tick). Pass
    # `permanent: false` when the trigger LABEL must update on a full
    # navigation — otherwise the old label is carried over (the metrics
    # dashboard switcher: navigating to another dashboard kept the old
    # name). Omit the attribute entirely when not permanent (Turbo keys
    # off attribute presence, so "false" would still pin it).
    data = {
      controller: "drawer",
      drawer_src_value: @src,
      drawer_min_width_value: @min_width,
      drawer_max_width_value: @max_width,
      drawer_resizable_value: @resizable.to_s,
      drawer_storage_key_value: @storage_key
    }
    data[:turbo_permanent] = true if @permanent

    div(id: @id, class: "contents", data: data) do
      render_trigger(&trigger_body)
      render_panel
    end
  end

  private

  # render_trigger — anchor (NOT button) so cmd-click / middle-click
  # still gets browser-native "open in new tab" behaviour. The
  # Stimulus action only fires on plain left-click.
  #
  # custom_trigger: render the block AS-IS (no wrapping anchor) — the
  # caller supplies its own element carrying `click->drawer#open`. Used
  # when the trigger lives inside richer markup (e.g. a dropdown menu)
  # but the drawer PANEL must stay a sibling of that markup so it isn't
  # hidden/clipped when the menu toggles.
  def render_trigger(&trigger_body)
    if @custom_trigger
      yield
      return
    end

    a(
      href: @open_url,
      data: {action: "click->drawer#open"},
      **@trigger_attrs,
      &trigger_body
    )
  end

  def render_panel
    aside(
      data: {drawer_target: "panel"},
      role: "dialog",
      "aria-modal": "false",
      "aria-labelledby": panel_title_id,
      # Inline `width` + `max-width` so the resize handle can mutate
      # `width` directly without fighting Tailwind classes, and the
      # max ceiling stays configurable per drawer instance (logs
      # drawer opts in to 85vw — see Components::Pods::Header
      # #view_logs_btn). Default `min(100vw, 1200px)` matches the
      # old hard-coded cap.
      style: "width: #{@width}; max-width: #{@max_width};",
      class: tokens(
        "fixed top-0 right-0 h-screen z-[60]",
        "flex flex-col",
        "bg-voodu-bg-2 border-l border-voodu-border",
        "shadow-[var(--voodu-shadow-drawer)]",
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
        action: "pointerdown->drawer#startResize"
      },
      aria: {hidden: "true"},
      title: "Drag to resize",
      class: "absolute top-0 left-0 bottom-0 w-1.5 -ml-1 cursor-col-resize hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-[5] touch-none"
    )
  end

  def panel_header
    # h-14 aligns with the topbar + sidebar brand so the three
    # bottom-borders draw one continuous line across the viewport
    # when the drawer is open. Width is the only axis that varies
    # between the three shell regions — the top row is unified.
    header(
      class: "flex items-center gap-2 px-4 h-14 border-b border-voodu-border bg-voodu-surface shrink-0"
    ) do
      h2(
        id: panel_title_id,
        class: "m-0 text-[13px] font-semibold text-voodu-text truncate flex-1 min-w-0"
      ) { @title }

      open_in_tab_link if @show_full_page_link
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
      data: {action: "click->drawer#close"},
      class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
    ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
  end

  def panel_body
    # `scrollbar-hidden` — auto-overflow without the visible scrollbar
    # track (operator preference; the bar feels noisy in a peek
    # surface). Wheel/touch/keyboard scroll still works.
    div(
      data: {drawer_target: "body"},
      class: "relative flex-1 overflow-auto scrollbar-hidden bg-voodu-bg"
    ) do
      # Spinning brand logo while the fetch is in flight. Replaced
      # in-place by drawer_controller.js when the response arrives.
      # `animate-voodu-spin` (theme.css) is a 0.9s linear infinite
      # rotation — same primitive the inline Spinner uses, applied
      # to the logo bitmap.
      #
      # Icon-only: the spinning brand mark reads as "loading" on
      # its own; the word adds noise without adding signal.
      div(class: "h-full flex items-center justify-center") do
        render img(
          src: "/mono-white-512.png",
          alt: "loading",
          class: "h-24 w-24 animate-voodu-spin opacity-80",
          aria: {label: "Loading"}
        )
      end
    end
  end

  def panel_title_id
    "drawer-title-#{object_id}"
  end
end
