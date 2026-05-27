# frozen_string_literal: true

# Components::Logs::Page — the entire Logs viewer chrome.
#
# Phlex renders the shell + toolbar + an empty viewport. The
# `log-stream` Stimulus controller (attached to the root div via
# data-controller) takes over from there: backfills 60 historical
# lines, opens a mock stream, applies filters, manages pause / wrap /
# follow / clear.
#
# Pass `pod_name:` to scope the stream to a single pod (the chip with
# "pod: docs.35a3 ×" shows up and links back to /logs); pass nil to
# stream from every known pod.
#
# When the PAT plane exposes a real log stream the controller swaps
# its mock generator for a fetch/SSE subscribe — everything else
# (filters, follow, paused, counters) is structural and stays.
class Components::Logs::Page < Components::Base
  # drawer: true → embedded inside Components::UI::Drawer (Metrics
  # page's "Logs" peek). Suppresses the "back to pod" link — the
  # drawer's own header already has a close + open-in-new-tab,
  # so "back to pod" would be a dead-end (the page outside the
  # drawer is still the Metrics page, not Pod detail).
  # pods: — full pod list (compact, no :detail) used to populate
  # the Components::Logs::PodPicker dropdown. When [] / nil the
  # picker is suppressed entirely (avoids rendering a dropdown
  # with only "All pods" inside). In drawer mode the picker is
  # ALSO suppressed because the drawer's header already names
  # the pod and the operator's mental model is "I'm peeking at
  # THIS pod's logs."
  #
  # back_to_pod: — render the "← Back to pod" link above the
  # heading. The controller sets this to true ONLY when the
  # Referer is the matching /<key>/pods/<name> page (the
  # "View logs" button on the pod detail header). Switching
  # pods via the in-page picker leaves it false so the link
  # doesn't point at a page the operator wasn't on.
  def initialize(pod_name: nil, drawer: false, pods: [], back_to_pod: false)
    @pod_name    = pod_name
    @drawer      = drawer
    @pods        = Array(pods)
    @back_to_pod = back_to_pod
  end

  def view_template
    div(
      class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 h-full",
      data: {
        controller: "log-stream",
        log_stream_pod_value:        @pod_name.to_s,
        # Stream URL routes:
        #
        #   - With pod_name → /logs/:name/stream
        #     (proxies /api/pat/v1/pods/:name/logs — one pod tail)
        #   - Without       → /logs/stream
        #     (proxies /api/pat/v1/logs — server-side fan-out across
        #     every pod, each line prefixed with [pod-name])
        #
        # Same JS controller handles both — the multi-source response
        # carries `[pod-name] ` line prefixes that the parser strips
        # to attribute each line to its origin pod.
        log_stream_stream_url_value: stream_url
      }
    ) do
      page_header
      toolbar
      viewport
    end
  end

  # show_pod_picker? — only on the full-page surface AND when we've
  # got real pods to populate the dropdown. Drawer mode hides it
  # (the drawer's title is already pod-specific) and empty `pods`
  # avoids showing a picker with only the "All pods" row.
  def show_pod_picker?
    !@drawer && @pods.any?
  end

  # show_open_pod? — render the "Open pod" drawer trigger only when
  # a specific pod is in view AND we're on the full page (drawer
  # mode is already inside a peek, no need to spawn another).
  def show_open_pod?
    !@drawer && @pod_name.present?
  end

  # toolbar — filter input + level pills + follow/wrap/pause/clear.
  # Single row that works for both full-page and drawer surfaces.
  def toolbar
    div(class: "flex flex-wrap items-center gap-2") do
      filter_input
      level_pills
      div(class: "flex-1")
      actions
    end
  end

  private

  # stream_url — controller's `docker logs -f` SSE proxy. Now that
  # the controller's log stream is served via the docker SDK (no
  # fork+exec per call) the per-pod `docker logs -f` cost is just
  # a long-lived HTTP connection to the daemon socket — cheap
  # enough to keep open while the operator watches. The realtime
  # UX (sub-second latency) is worth more than the few persistent
  # connections during a debug session.
  #
  # The warehouse path (`logs_warehouse_stream_path`) is still
  # registered + used by exports for historical reads; it's just
  # not the realtime feed anymore.
  #
  # tail=0 — operator decision: open the page and ONLY see lines
  # that arrive from this moment forward. No backfill of recent
  # context. Cleaner first-paint for debug sessions where the
  # operator is about to reproduce something and wants the
  # viewport empty to attribute every new line to their action.
  # Historical reads / scrollback live behind a filter UI
  # (planned) that hits the warehouse on demand.
  def stream_url
    if @pod_name
      "#{pod_log_stream_path(name: @pod_name)}?follow=true&tail=0"
    else
      "#{logs_stream_path}?follow=true&tail=0"
    end
  end

  # page_header — H1 "Logs" + live counters subline + actions
  # cluster on the right (pod picker, "Open pod" drawer trigger
  # when scoped). Uses the shared Components::UI::PageHeader so the
  # visual rhythm matches the Metrics page exactly.
  #
  # The "back to pod" link stays OUTSIDE the PageHeader (rendered
  # above) because PageHeader's job is "title + actions" — adding
  # an above-title slot just for this one case would bloat the
  # primitive.
  def page_header
    div(class: "flex flex-col gap-3") do
      back_link if show_back_link?
      render(
        Components::UI::PageHeader.new(title: "Logs")
          .with_subtitle { sub_line }
          .with_actions do
            if show_pod_picker?
              render Components::Logs::PodPicker.new(active_pod: @pod_name, pods: @pods)
            end
            open_pod_btn if show_open_pod?
          end
      )
    end
  end

  # open_pod_btn — Drawer trigger that mirrors the Metrics page's
  # "Open pod" action. Clicking peeks the pod detail in a right
  # drawer instead of navigating away (the same Stimulus drawer
  # the Metrics surface uses, so the operator's persisted width
  # preference carries over).
  def open_pod_btn
    render(Components::UI::Drawer.new(
      title:    "Pod · #{@pod_name}",
      src:      "#{pod_path(name: @pod_name)}?embed=1",
      open_url: pod_path(name: @pod_name),
      width:    "70vw",
      trigger_attrs: {
        class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
      }
    )) do
      render Icon::ArrowTopRightOnSquareOutline.new(class: "w-3.5 h-3.5")
      span { "Open pod" }
    end
  end

  # show_back_link? — three gates:
  #   - we have a pod_name (back-link target is /pods/<name>)
  #   - we're NOT in drawer mode (drawer has its own close X)
  #   - the operator actually came from the pod detail page
  #     (controller checks Referer; in-page picker navigation
  #     leaves @back_to_pod false so the link doesn't redirect
  #     to a page the operator wasn't on)
  def show_back_link?
    @pod_name && !@drawer && @back_to_pod
  end

  def back_link
    a(
      href: pod_path(name: @pod_name),
      class: "inline-flex items-center gap-1.5 self-start text-[12.5px] text-voodu-text-2 hover:text-voodu-text"
    ) do
      render Icon::ArrowLeftOutline.new(class: "w-3.5 h-3.5")
      span { "Back to pod" }
    end
  end

  def sub_line
    div(class: "flex flex-wrap items-center gap-2.5 mt-1 text-[12.5px] text-voodu-muted") do
      streaming_state
      dot_sep
      stat(:rate, "0", " lines/sec")
      dot_sep
      stat(:buffer, "0", " in buffer")
      dot_sep
      stat(:visible, "0", " visible")
      dot_sep
      stat(:sources, "0", lambda { " source#{'s' unless @pod_name}" })
    end
  end

  def streaming_state
    span(class: "inline-flex items-center gap-1.5") do
      span(
        data: { log_stream_target: "stateDot" },
        class: "inline-block w-1.5 h-1.5 rounded-full animate-voodu-pulse",
        style: "background: var(--voodu-green); box-shadow: 0 0 0 3px color-mix(in srgb, var(--voodu-green) 18%, transparent);"
      )
      span(data: { log_stream_target: "stateLabel" }) { "streaming live" }
    end
  end

  def stat(target, initial, label)
    span do
      span(class: "font-voodu-mono text-voodu-text-2", data: { log_stream_target: target.to_s }) { initial }
      label_text = label.respond_to?(:call) ? label.call : label
      plain label_text
    end
  end

  def dot_sep
    span(
      class: "inline-block w-[3px] h-[3px] rounded-full bg-voodu-border-2",
      aria: { hidden: "true" }
    )
  end

  def filter_input
    div(
      class: "flex items-center gap-2 px-2.5 h-8 border border-voodu-border bg-voodu-surface flex-1 min-w-[200px] max-w-[420px] text-voodu-muted"
    ) do
      render Icon::MagnifyingGlassOutline.new(class: "w-3.5 h-3.5 shrink-0")
      input(
        type: "search",
        placeholder: "filter by path, method, status, message…",
        data: {
          log_stream_target: "filter",
          action: "input->log-stream#applyFilter"
        },
        class: "flex-1 bg-transparent border-0 outline-none text-[12px] text-voodu-text placeholder:text-voodu-muted-2 h-full"
      )
    end
  end

  LEVEL_PILLS = %w[HTTP INFO WARN ERROR].freeze
  LEVEL_DEFAULT_TONE = {
    "HTTP"  => { color: "#60a5fa", bg: "rgba(96,165,250,0.12)",  border: "rgba(96,165,250,0.40)"  },
    "INFO"  => { color: "#9a82ff", bg: "rgba(124,92,255,0.12)",  border: "rgba(124,92,255,0.40)"  },
    "WARN"  => { color: "#fbbf24", bg: "rgba(251,191,36,0.12)",  border: "rgba(251,191,36,0.40)"  },
    "ERROR" => { color: "#f87171", bg: "rgba(248,113,113,0.14)", border: "rgba(248,113,113,0.45)" }
  }.freeze

  def level_pills
    div(class: "inline-flex border border-voodu-border bg-voodu-surface p-[2px]", role: "tablist") do
      LEVEL_PILLS.each { |l| level_pill(l) }
    end
  end

  def level_pill(level)
    tone = LEVEL_DEFAULT_TONE[level]

    # Default state = active (all levels visible). Pre-paint with the
    # tone colours so the markup matches what the JS will toggle.
    button(
      type: "button",
      role: "tab",
      "aria-selected": "true",
      data: {
        log_stream_target: "level",
        level: level,
        action: "click->log-stream#toggleLevel",
        active: "true"
      },
      class: "inline-flex items-center px-2.5 h-7 text-[11px] font-bold font-voodu-mono tracking-wider border border-transparent",
      style: "color: #{tone[:color]}; background: #{tone[:bg]}; border-color: #{tone[:border]};"
    ) { level }
  end

  def actions
    div(class: "flex items-center gap-1.5 flex-wrap") do
      follow_btn
      wrap_btn
      pause_btn
      copy_all_btn
      clear_btn
      # Export drawer trigger — last action so the destructive-ish
      # workflow ("generate file, download") doesn't crowd the
      # live-tail toggles. Hidden in drawer mode (Metrics peek)
      # because the peek already has limited width and an export
      # there would mean the operator can't see the live tail
      # while picking a period.
      render Components::Logs::ExportButton.new(current_pod: @pod_name) unless @drawer
    end
  end

  # copy_all_btn — bulk version of the per-row copy affordance. Reads
  # `body.textContent` from every currently-visible row (respects level
  # pill filters + the search filter) and joins them with newlines into
  # one clipboard write. Bypasses scroll position — the operator
  # doesn't have to drag-select page-by-page to grab a long viewport.
  #
  # Same payload-only semantics as the per-row icon: no timestamps,
  # no level chips, no pod names, no IPs. The raw lines already carry
  # `"time":...` fields in their JSON, so paste-into-LLM/paste-into-
  # an-incident-doc workflows stay clean.
  def copy_all_btn
    button(
      type: "button",
      data: { action: "click->log-stream#copyAll" },
      class: "inline-flex items-center gap-1.5 px-3 h-8 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      # Inline SVG (no Icon component) so the markup matches the
      # per-row copy glyph in log_stream_controller.js — same shape,
      # same affordance language.
      svg(
        viewBox: "0 0 16 16", fill: "none", stroke: "currentColor",
        "stroke-width": "1.5", "stroke-linecap": "round", "stroke-linejoin": "round",
        class: "w-3 h-3", "aria-hidden": "true"
      ) do |s|
        s.rect(x: "5", y: "5", width: "9", height: "9", rx: "1.2")
        s.path(d: "M11 5V3a1 1 0 0 0-1-1H3a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1h2")
      end
      span(data: { copy_all_label: true }) { "Copy all" }
    end
  end

  # follow_btn + wrap_btn — both true toggles. Visual state lives
  # in JS: log_stream_controller.js#refreshToggleButton swaps two
  # class sets (TOGGLE_ACTIVE_CLASSES vs TOGGLE_INACTIVE_CLASSES,
  # defined alongside the same constants in the JS file) based on
  # the live state. Same chrome both buttons share when active —
  # purple-dim chip — so the pair reads coherently in the toolbar.
  #
  # Markup boots with the ACTIVE class list because both toggles
  # default to true (follow on, wrap on). Connect() in the
  # controller calls refreshToggleButton(target, true/false) so
  # any future default flip is one place.
  #
  # Why class swap instead of Tailwind `data-[active=true]:*`
  # variants? Tailwind 4's source scanner didn't reliably emit
  # those CSS rules for our setup; class swap is portable and
  # explicit. Less elegant but works everywhere.

  def follow_btn
    button(
      type: "button",
      data: {
        log_stream_target: "follow",
        action: "click->log-stream#toggleFollow",
        active: "true"
      },
      # Both class sets MUST stay reachable to Tailwind's source
      # scanner — listing them inline here (rather than building
      # the string in JS) is what keeps both purple AND neutral
      # variants in the final CSS bundle.
      class: "inline-flex items-center gap-1.5 px-3 h-8 border text-[12px] font-medium border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
    ) do
      # Live dot — green + pulsing when Follow is active, muted +
      # static when toggled off. CSS-driven via the parent button's
      # [data-active] attribute (see .voodu-live-dot in theme.css),
      # so the JS toggle that already flips data-active also drives
      # the dot state — no extra target needed.
      span(class: "voodu-live-dot")
      span { "Follow" }
    end
  end

  # wrap_btn — defaults to INACTIVE. Operator preference: long lines
  # stay single-line with horizontal scroll so the column rhythm and
  # drag-select-payload UX stay clean in dense viewports. Toggle on
  # for stack-trace / multi-KB JSON inspection.
  #
  # Markup matches the inactive Pause/Clear chrome (neutral surface
  # chip) so first paint reads the same as the live state. Class
  # swap to active state is driven by log_stream_controller.js
  # refreshToggleButton on click — same machinery as the Follow btn.
  def wrap_btn
    button(
      type: "button",
      data: {
        log_stream_target: "wrap",
        action: "click->log-stream#toggleWrap",
        active: "false"
      },
      class: "inline-flex items-center px-3 h-8 border text-[12px] font-medium border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) { "Wrap" }
  end

  # tailwind_source_anchor — invisible div whose only purpose is to
  # hold the INACTIVE toggle classes as a string so the Tailwind
  # source scanner keeps them in the bundle. The buttons start
  # ACTIVE, so without this anchor the inactive classes would never
  # appear in the rendered HTML at boot and the JIT compiler would
  # tree-shake them out. The JS toggle then would set classNames
  # that have no matching CSS.
  #
  # Don't render this — it's only here so the strings exist in the
  # .rb source for the @source scanner to pick up. (Phlex requires
  # something callable; we never invoke it.)
  #
  # If you remove this method, also remove the same strings from
  # log_stream_controller.js's TOGGLE_INACTIVE_CLASSES — otherwise
  # the inactive state will fall back to unstyled.
  TOGGLE_INACTIVE_CLASSES_FOR_TAILWIND_SOURCE = [
    "border-voodu-border",
    "bg-voodu-surface",
    "text-voodu-text-2",
    "hover:bg-voodu-surface-2",
    "hover:text-voodu-text"
  ].freeze

  def pause_btn
    button(
      type: "button",
      data: {
        log_stream_target: "pause",
        action: "click->log-stream#togglePause"
      },
      class: "inline-flex items-center gap-1.5 px-3 h-8 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      render Icon::PauseOutline.new(class: "w-3 h-3")
      span(data: { pause_label: true }) { "Pause" }
    end
  end

  def clear_btn
    button(
      type: "button",
      data: { action: "click->log-stream#clear" },
      class: "inline-flex items-center gap-1.5 px-3 h-8 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      render Icon::XMarkOutline.new(class: "w-3 h-3")
      span { "Clear" }
    end
  end

  # viewport — scrollable container the controller writes into.
  # Empty state lives inside; controller flips its `hidden` based on
  # visibleCount.
  #
  # `group` enables Tailwind's group-hover pattern on the floating
  # affordances. `jump_to_top` opacities-in when the mouse enters the
  # viewport (operator hovers the log stream); pure CSS, no JS state
  # to manage. `jump_to_live` keeps its existing Stimulus-driven
  # show/hide because it's also tied to scroll position (auto-shows
  # when the operator scrolls away from the tail), which CSS alone
  # can't express.
  def viewport
    div(class: "flex-1 min-h-[280px] bg-voodu-bg-2 border border-voodu-border flex flex-col overflow-hidden relative group") do
      # pb-1.5 (not py-1.5) — top padding on a scrolling container
      # gets honoured by `position: sticky; top: 0` as a 6px gap
      # above the column header on initial load (sticky anchors to
      # the padding edge of the scrollport). Dropping padding-top
      # while keeping padding-bottom: header sits flush against the
      # viewport's top border, last log row keeps a breathing strip
      # before the bottom border.
      div(
        class: "flex-1 overflow-auto pb-1.5 min-w-0",
        tabindex: "0",
        role: "log",
        "aria-label": "Log stream",
        data: {
          log_stream_target: "viewport",
          action: "scroll->log-stream#onScroll"
        }
      ) do
        # log-list — outer grid container so every row shares ONE
        # column template (ts / level / pod / ip / body). With each
        # row marked `display: contents` (theme.css), the cells flow
        # directly into this grid, so the pod column auto-sizes to
        # the widest pod name across the entire viewport instead of
        # zig-zagging per-row. See `.log-list` / `.log-row` rules in
        # voodu/theme.css for the layout invariants.
        #
        # Rendered BEFORE the empty-state placeholder so the sticky
        # column header sits at the very top of the scroll area — the
        # operator orients themselves on the column labels even before
        # the first line arrives.
        div(class: "log-list", data: { log_stream_target: "list" }) do
          column_header
        end

        div(
          data: { log_stream_target: "empty" },
          class: "px-4 py-10 text-center text-voodu-muted text-[12.5px]"
        ) { "Waiting for log lines…" }
      end

      jump_to_top
      jump_to_live
    end
  end

  # column_header — sticky column-name strip at the top of the log
  # list. Rendered as a `.log-row.log-header` so its 5 cells flow into
  # the same outer grid as the data rows — column widths stay
  # perfectly aligned even when pod names grow long enough to expand
  # the data column. Each cell is `position: sticky; top: 0` so the
  # header stays pinned while the operator scrolls through the buffer.
  #
  # JS iterations over `.log-list` children (applyFilter, copyAll,
  # buffer-cap drop, clear) explicitly skip elements with the
  # `.log-header` class so the schema row never gets hidden, copied,
  # or evicted with the data rows.
  #
  # `aria-hidden="true"` — the toolbar's filter input description
  # ("filter by path, ip, method, status, message…") already names the
  # columns for screen readers. The visual header is decorative
  # orientation chrome, not navigation.
  def column_header
    div(class: "log-row log-header", "aria-hidden": "true") do
      span(class: "log-hcell log-h-ts")    { "TIME" }
      span(class: "log-hcell log-h-level") { "LVL" }
      span(class: "log-hcell log-h-pod")   { "POD" }
      span(class: "log-hcell log-h-body")  { "PAYLOAD" }
    end
  end

  # jump_to_top — hover-only affordance. The mirror of jump_to_live
  # (top-center vs bottom-center). Visible only while the cursor is
  # inside the viewport box (`group-hover:opacity-100`) — keeps the
  # log surface clean when the operator's reading and reveals the
  # control exactly when they're considering using it.
  #
  # `pointer-events-none` when hidden so the invisible button doesn't
  # eat clicks targeting log lines underneath it during the fade.
  # Styling matches the toolbar's secondary chrome (border-voodu-
  # border + bg-voodu-surface) rather than the accent palette used
  # by jump_to_live — top is a navigation aid, not a primary CTA.
  def jump_to_top
    button(
      type: "button",
      title: "Jump to top",
      "aria-label": "Jump to top of log stream",
      data: { action: "click->log-stream#jumpToTop" },
      # top-10 (40px) clears the ~22px sticky column header + a small
      # gap so the chip feels "inside the log area," not glued to the
      # header. z-20 wins against the header's z-index: 2 (theme.css
      # `.log-header > .log-hcell`) so the chip stays visible during
      # scroll instead of disappearing behind the schema row.
      class: "absolute left-1/2 -translate-x-1/2 top-10 z-20 inline-flex items-center gap-1.5 px-3 h-8 " \
             "border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium shadow-2xl " \
             "opacity-0 pointer-events-none transition-opacity duration-150 " \
             "group-hover:opacity-100 group-hover:pointer-events-auto " \
             "hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      render Icon::ChevronUpOutline.new(class: "w-3 h-3")
      span { "Jump to top" }
    end
  end

  def jump_to_live
    button(
      type: "button",
      hidden: true,
      data: {
        log_stream_target: "jumpToLive",
        action: "click->log-stream#jumpToLive"
      },
      class: "absolute left-1/2 -translate-x-1/2 bottom-3.5 inline-flex items-center gap-1.5 px-3 h-8 border border-voodu-accent-line bg-voodu-accent text-white text-[12px] font-medium shadow-2xl"
    ) do
      render Icon::ChevronDownOutline.new(class: "w-3 h-3")
      span { "Jump to live" }
    end
  end
end
