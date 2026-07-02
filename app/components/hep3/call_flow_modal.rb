# frozen_string_literal: true

# Components::Hep3::CallFlowModal — the overlay that hosts the call-flow
# ladder. Wraps Components::UI::Modal (:xl) so it injects + auto-connects
# like the Logs "surrounding" modal: the row's call-flow icon fetches
# Hep3Controller#call, drops this fragment into the page host, and the
# modal_controller takes over ESC / backdrop (the host clears the DOM on
# `modal:close`).
#
# Layout: the ladder on the left (scrolls), a raw-SIP panel on the right
# (stacked under the ladder on narrow viewports). Clicking an arrow in
# the ladder selects its message; call_flow_controller.js swaps the raw
# panel to that message's SIP. The messages' raw payloads ride along as a
# Stimulus Array value so selection needs no extra fetch.
class Components::Hep3::CallFlowModal < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    render(Components::UI::Modal.new(
      title: title, subtitle: subtitle, icon: :PhoneArrowUpRightOutline, size: :xl
    )) do
      @data.found? ? flow_body : empty_state
    end
  end

  private

  # flow_body — FIXED height (h-[82vh], capped on short screens) so the modal
  # doesn't resize as the raw panel swaps between a 4-line 100 Trying and a
  # 60-line INVITE+SDP. Ladder + raw each scroll inside the stable shell.
  def flow_body
    div(
      class: "flex flex-col vmd:flex-row h-[82vh] max-h-[calc(100vh-104px)]",
      data: {
        controller: "call-flow",
        call_flow_messages_value: messages_payload.to_json,
        call_flow_focus_value: @data.focus_index,
        call_flow_scope_value: @data.scope,
        call_flow_name_value: @data.name,
        call_flow_corr_value: @data.corr_id
      }
    ) do
      div(class: "flex-1 min-w-0 min-h-0 flex flex-col relative") do
        ladder_toolbar

        div(
          tabindex: "-1",
          data: {call_flow_target: "ladder", action: "mouseenter->call-flow#ladderEnter mouseleave->call-flow#ladderLeave"},
          class: tokens(
            "flex-1 min-w-0 min-h-0 overflow-auto p-3 bg-voodu-bg focus:outline-none",
            ("pb-9" if @data.gap_media.any?)
          )
        ) do
          render Components::Hep3::CallFlow.new(data: @data)
        end

        media_footer
      end

      raw_panel
    end
  end

  # ladder_toolbar — a non-scrolling strip above the diagram: the keyboard
  # hint + a Refresh button (re-fetches THIS call in place, so the operator
  # can watch a live call grow without reloading the page).
  def ladder_toolbar
    div(class: "flex items-center gap-2 px-3 py-1.5 border-b border-voodu-border shrink-0") do
      span(class: "text-[10.5px] text-voodu-muted-2 hidden vmd:block") do
        "↑ / ↓ to step messages (hover the diagram)"
      end

      button(
        type: "button",
        data: {action: "click->call-flow#refresh"},
        title: "Refresh this call", "aria-label": "Refresh this call",
        class: "inline-flex items-center gap-1.5 px-2 h-7 ml-auto border border-voodu-border " \
               "bg-voodu-surface text-voodu-text-2 text-[11.5px] hover:bg-voodu-surface-2"
      ) do
        render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5")
        span(class: "hidden vmd:inline") { "Refresh" }
      end
    end
  end

  # raw_panel — the SIP detail, seeded with the FOCUSED message (the clicked
  # row, or the call's first). Collapse chevron in the header (a real row, like
  # the media footer): in COLUMN it collapses the body (frees the diagram's
  # height); in ROW it collapses to a thin left strip (frees the diagram's
  # width) and the left edge resizes. Width is proportional (clamped) so it
  # adapts to the viewport. All state persisted by call_flow_controller.
  def raw_panel
    focus = @data.focus_message

    div(
      data: {call_flow_target: "rawPanel"},
      class: "relative flex flex-col min-h-0 flex-1 vmd:flex-none vmd:w-[clamp(300px,32vw,560px)] " \
             "border-t vmd:border-t-0 vmd:border-l border-voodu-border bg-voodu-surface"
    ) do
      div(
        data: {call_flow_target: "resizeHandle", action: "pointerdown->call-flow#startResize"},
        aria: {hidden: "true"}, title: "Drag to resize",
        class: "hidden vmd:block absolute top-0 left-0 bottom-0 w-1.5 -ml-1 cursor-col-resize " \
               "hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-[5] touch-none"
      )

      button(
        type: "button",
        style: "display: none;",
        data: {call_flow_target: "reopen", action: "click->call-flow#expandPanel"},
        title: "Show SIP message", "aria-label": "Show SIP message",
        class: "absolute inset-y-0 left-0 w-9 flex-col items-center justify-center gap-2 " \
               "text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2"
      ) do
        render Icon::ChevronLeftOutline.new(class: "w-4 h-4")
        span(class: "text-[10px] tracking-[0.1em] [writing-mode:vertical-rl] rotate-180") { "SIP" }
      end

      div(data: {call_flow_target: "content"}, class: "flex flex-col min-h-0 flex-1") do
        button(
          type: "button",
          data: {action: "click->call-flow#togglePanel"},
          "aria-label": "Toggle SIP message",
          class: "w-full flex items-center gap-1.5 px-3 py-2 border-b border-voodu-border shrink-0 text-left hover:bg-voodu-surface-2"
        ) do
          div(class: "min-w-0 flex-1") do
            div(
              class: "text-[12px] font-semibold text-voodu-text font-voodu-mono truncate",
              data: {call_flow_target: "rawLabel"}
            ) { focus[:label] }

            div(
              class: "text-[10.5px] text-voodu-muted mt-0.5 truncate",
              data: {call_flow_target: "rawMeta"}
            ) { meta_line(focus) }
          end

          span(
            data: {call_flow_target: "chevron"},
            "aria-hidden": "true",
            class: "ml-auto shrink-0 inline-flex items-center justify-center w-4 h-4 text-voodu-muted transition-transform"
          ) { render Icon::ChevronDownOutline.new(class: "w-3.5 h-3.5") }
        end

        pre(
          class: "flex-1 overflow-auto text-[11px] leading-[1.5] font-voodu-mono text-voodu-text-2 " \
                 "p-3 whitespace-pre-wrap break-words",
          data: {call_flow_target: "rawBody"}
        ) { focus[:raw_sip].presence || "(no raw SIP captured for this message)" }
      end
    end
  end

  # media_footer — media whose RTP endpoint ISN'T a SIP lifeline ("gap": RTP on
  # a different host than signalling, so it can't sit inline in the ladder like
  # the on-lifeline streams do). Rendered as a COLLAPSED (default) strip pinned
  # to the bottom of the flow column; expanding overlays the diagram (which
  # scrolls underneath) instead of pushing it. In-lifeline media is drawn in
  # the ladder itself (Components::Hep3::CallFlow), not here.
  def media_footer
    streams = @data.gap_media
    return if streams.empty?

    div(class: "absolute inset-x-0 bottom-0 z-10", data: {call_flow_target: "mediaFooter"}) do
      div(
        data: {call_flow_target: "mediaBody"},
        class: "hidden max-h-[45%] overflow-auto border-t border-voodu-border bg-voodu-surface-2 p-2 flex flex-col gap-1 shadow-[0_-8px_24px_rgba(0,0,0,0.4)]"
      ) do
        streams.each { |stream| media_row(stream) }
      end

      button(
        type: "button",
        data: {action: "click->call-flow#toggleMedia"},
        class: "w-full flex items-center gap-2 px-3 h-7 border-t border-voodu-border bg-voodu-surface " \
               "text-voodu-muted-2 text-[10.5px] hover:bg-voodu-surface-2"
      ) do
        render Icon::SignalOutline.new(class: "w-3.5 h-3.5 shrink-0")
        span(class: "font-semibold uppercase tracking-[0.06em]") { "media (RTP)" }
        span { "#{streams.size} #{(streams.size == 1) ? "stream" : "streams"} · derived from SDP" }
        span(
          data: {call_flow_target: "mediaChevron"},
          "aria-hidden": "true",
          class: "ml-auto shrink-0 inline-flex items-center justify-center w-4 h-4 transition-transform"
        ) { render Icon::ChevronUpOutline.new(class: "w-3.5 h-3.5") }
      end
    end
  end

  def media_row(stream)
    div(class: "flex flex-col gap-0.5 px-2.5 py-1.5 bg-voodu-surface rounded-voodu-sm border border-voodu-border") do
      div(class: "flex items-center gap-2 text-[11.5px] font-voodu-mono text-voodu-text min-w-0") do
        span(class: "truncate") { stream[:offer] }
        render Icon::ArrowsRightLeftOutline.new(class: "w-3 h-3 shrink-0 text-voodu-muted")
        span(class: "truncate") { stream[:answer] }

        unless stream[:answered]
          span(class: "text-[10px] text-voodu-amber shrink-0") { "offered" }
        end
      end

      div(class: "text-[10.5px] text-voodu-muted font-voodu-mono") do
        plain [stream[:codecs].join(", ").presence, stream[:direction]].compact.join(" · ")
      end
    end
  end

  def empty_state
    div(class: "flex flex-col items-center justify-center gap-2 py-16 px-6 text-center") do
      render Icon::PhoneXMarkOutline.new(class: "w-8 h-8 text-voodu-muted-2")
      div(class: "text-[13px] font-semibold text-voodu-text") { "Call not found" }
      div(class: "text-[11.5px] text-voodu-muted font-voodu-mono break-all") { @data.corr_id }
      div(class: "text-[11.5px] text-voodu-muted") do
        "No messages captured for this call in the selected reader."
      end
    end
  end

  # messages_payload — the per-message raw SIP + meta the client keeps for
  # instant selection (no re-fetch). Kept small: label/ts/endpoints/raw.
  def messages_payload
    @data.messages.map do |m|
      {
        id: m[:id],
        label: m[:label],
        ts: m[:ts],
        src: endpoint(m[:src], m[:src_port]),
        dst: endpoint(m[:dst], m[:dst_port]),
        raw: m[:raw_sip]
      }
    end
  end

  def endpoint(ip, port)
    port.to_s.empty? ? ip.to_s : "#{ip}:#{port}"
  end

  def meta_line(message)
    return "" if message.nil?

    "#{message[:ts]} · #{endpoint(message[:src], message[:src_port])} → #{endpoint(message[:dst], message[:dst_port])}"
  end

  def title
    s = @data.summary
    parties = [s[:from_user].presence, s[:to_user].presence].compact

    parties.any? ? parties.join(" → ") : @data.corr_id
  end

  def subtitle
    s = @data.summary
    bits = ["#{s[:count]} #{(s[:count] == 1) ? "message" : "messages"}"]
    bits << "final #{s[:last_code]}" if s[:last_code]
    bits << humanized_duration(s[:duration_ms])

    bits.compact.join(" · ")
  end

  def humanized_duration(ms)
    return nil if ms.nil? || ms.zero?
    return "#{ms}ms" if ms < 1000

    "#{(ms / 1000.0).round(1)}s"
  end
end
