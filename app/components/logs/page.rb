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
      pod_picker_row if show_pod_picker?
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

  # pod_picker_row — its own toolbar row (matches the Metrics page
  # layout where the scope picker sits in a dedicated row between
  # page-head and the chart toolbar).
  def pod_picker_row
    div(class: "flex items-center gap-2 flex-wrap") do
      render Components::Logs::PodPicker.new(active_pod: @pod_name, pods: @pods)
    end
  end

  private

  def stream_url
    if @pod_name
      "#{helpers.pod_log_stream_path(name: @pod_name)}?follow=true&tail=50"
    else
      "#{helpers.logs_stream_path}?follow=true&tail=50"
    end
  end

  # page_header — H1 "Logs" + live counters subline, with a "back to
  # pod detail" link above the heading when the viewer is scoped to
  # a single pod (matches the Pod show page's "← All pods" pattern).
  def page_header
    div(class: "flex flex-col gap-3") do
      back_link if @pod_name && !@drawer
      div do
        h1(class: "text-[22px] font-semibold text-voodu-text tracking-tight") { "Logs" }
        sub_line
      end
    end
  end

  def back_link
    a(
      href: helpers.pod_path(name: @pod_name),
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
      pod_chip if @pod_name
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

  # Chip "pod: docs.35a3 ×" — leads back to the un-scoped /logs.
  def pod_chip
    short = short_pod(@pod_name)
    a(
      href: helpers.logs_path,
      class: "inline-flex items-center gap-1 px-2 py-[2px] border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 font-voodu-mono text-[11px] no-underline ml-1",
      aria: { label: "Clear pod filter" }
    ) do
      span { "pod: #{short}" }
      render Icon::XMarkOutline.new(class: "w-2.5 h-2.5")
    end
  end

  # "clowk-vd-docs.35a3" → "docs.35a3"
  def short_pod(name)
    dot = name.index(".")
    return name unless dot

    left = name[0...dot]
    dash = left.rindex("-")
    base = dash ? left[(dash + 1)..] : left
    "#{base}#{name[dot..]}"
  end

  # toolbar — filter input + level pills + follow/wrap/pause/clear.
  def toolbar
    div(class: "flex flex-wrap items-center gap-2") do
      filter_input
      level_pills
      div(class: "flex-1")
      actions
    end
  end

  def filter_input
    div(
      class: "flex items-center gap-2 px-2.5 h-8 border border-voodu-border bg-voodu-surface flex-1 min-w-[200px] max-w-[420px] text-voodu-muted"
    ) do
      render Icon::MagnifyingGlassOutline.new(class: "w-3.5 h-3.5 shrink-0")
      input(
        type: "search",
        placeholder: "filter by path, ip, method, status, message…",
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
      clear_btn
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

  # wrap_btn — defaults to ACTIVE. Long log lines (JSON dumps,
  # stack traces) wrap by default; toggle off when the operator
  # wants raw line geometry with horizontal scroll.
  def wrap_btn
    button(
      type: "button",
      data: {
        log_stream_target: "wrap",
        action: "click->log-stream#toggleWrap",
        active: "true"
      },
      class: "inline-flex items-center px-3 h-8 border text-[12px] font-medium border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
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
  def viewport
    div(class: "flex-1 min-h-[280px] bg-voodu-bg-2 border border-voodu-border flex flex-col overflow-hidden relative") do
      div(
        class: "flex-1 overflow-auto py-1.5 min-w-0",
        tabindex: "0",
        role: "log",
        "aria-label": "Log stream",
        data: {
          log_stream_target: "viewport",
          action: "scroll->log-stream#onScroll"
        }
      ) do
        div(
          data: { log_stream_target: "empty" },
          class: "px-4 py-10 text-center text-voodu-muted text-[12.5px]"
        ) { "Waiting for log lines…" }

        div(data: { log_stream_target: "list" })
      end

      jump_to_live
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
