# frozen_string_literal: true

# Components::LogAnalytics::SurroundingModal — the Surrounding Logs
# overlay body. Wraps Components::UI::Modal (size :xl) so it inherits the
# backdrop + scroll-lock + ESC handling. No close_to: the X fires
# modal#close, which dispatches `modal:close`; the log-analytics
# controller catches that (bubbled to the page root) and empties the
# host, tearing the overlay down without a navigation.
#
# Body: a context strip (count + scope toggle + export this batch), then
# the window of Row components newest-first (matching the result list;
# anchor highlighted + tagged for scroll-into-view), ending in a "Load
# more" trigger when a wider window would reveal more lines.
#
# Export stays IN the modal: the Copy button fetches the export endpoint;
# the Download links carry data-turbo=false so the browser handles the
# attachment with no navigation — neither closes the dialog (they live
# inside it, not on the backdrop).
class Components::LogAnalytics::SurroundingModal < Components::Base
  include Components::LogAnalytics::ColumnChrome
  include Components::LogAnalytics::CallId

  def initialize(data:)
    @data = data
  end

  def view_template
    render(
      Components::UI::Modal.new(
        title: "Surrounding logs",
        subtitle: subtitle,
        icon: :ArrowsPointingOutOutline,
        size: :xl
      )
    ) do
      context_strip
      window_body
    end
  end

  private

  def subtitle
    parts = [@data.pod.presence || "all pods"]
    parts << "around #{@data.anchor_ts}" if @data.anchor_ts.present?
    parts.join(" · ")
  end

  # context_strip — fixed band above the scroller (shrink-0, NOT sticky):
  # the rows now scroll inside their own `.la-cols-host` scroller below, so
  # the count + export + scope stay put without competing with the column
  # header for `top: 0` (that overlap was what hid the sticky header before).
  def context_strip
    div(class: "shrink-0 flex flex-wrap items-center justify-between gap-2 px-4 py-2 border-b border-voodu-border bg-voodu-bg-2") do
      div(class: "text-[11px] text-voodu-muted") do
        if @data.found?
          plain "#{@data.rows.size} lines around the selected line"
        else
          plain "Anchor line not found — showing the nearest window"
        end
      end

      div(class: "flex items-center gap-2") do
        call_flow_button if call_flow_available?
        export_cluster
        scope_toggle
      end
    end
  end

  # call_flow_button — the Logs→HEP3 bridge for the whole window: opens the
  # SIP ladder for the ANCHOR line's Call-ID, without closing the surrounding
  # context (the ladder is a separate overlay on top). Shown only when the
  # anchor carries a Call-ID and the island runs voodu-hep3 — the per-row
  # chips still cover any other captured line in the window.
  def call_flow_button
    button(
      type: "button",
      title: "Open the SIP call-flow for this call",
      data: {action: "click->log-analytics#openCallFlow", call_id: anchor_call_id},
      class: "inline-flex items-center gap-1 px-2 h-6 border border-voodu-accent-line bg-voodu-accent-dim text-[11px] font-medium text-voodu-accent-2 hover:text-voodu-text transition-colors"
    ) do
      render Icon::ArrowsRightLeftOutline.new(class: "w-3 h-3")
      span { "Call-flow" }
    end
  end

  def call_flow_available?
    anchor_call_id.present? && current_island&.plugin_installed?("hep3")
  end

  # anchor_call_id — the Call-ID of the line the modal is anchored on (nil
  # when the anchor wasn't located, or the line has no Call-ID). Precise to
  # the anchor: the button opens the call the operator drilled into, not some
  # other line that happens to share the window.
  def anchor_call_id
    return @anchor_call_id if defined?(@anchor_call_id)

    idx = @data.anchor_index
    @anchor_call_id = idx && sip_call_id_from(@data.rows[idx][:raw])
  end

  # export_cluster — export THIS batch (the exact window shown, same
  # expand/scope) without leaving the modal. Copy fetches the endpoint;
  # Download links the attachment (data-turbo=false → no navigation).
  def export_cluster
    div(class: "inline-flex items-center gap-1") do
      export_copy("Copy CSV", "csv")
      export_download("CSV", "csv")
      export_download("NDJSON", "ndjson")
    end
  end

  def export_copy(label, fmt)
    button(
      type: "button",
      title: "Copy this batch as #{fmt.upcase}",
      data: {action: "click->log-analytics#copyExport", export_url: surrounding_url(fmt: fmt)},
      class: export_btn_class
    ) do
      render Icon::ClipboardDocumentOutline.new(class: "w-3 h-3")
      span { label }
    end
  end

  def export_download(label, fmt)
    a(
      href: surrounding_url(fmt: fmt),
      download: "",
      title: "Download this batch as #{label}",
      data: {turbo: false},
      class: export_btn_class
    ) do
      render Icon::ArrowDownTrayOutline.new(class: "w-3 h-3")
      span { label }
    end
  end

  def export_btn_class
    "inline-flex items-center gap-1 px-2 h-6 border border-voodu-border bg-voodu-surface text-[11px] font-medium text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors"
  end

  def scope_toggle
    div(class: "inline-flex items-center gap-px p-[2px] border border-voodu-border bg-voodu-surface") do
      scope_button("This pod", all_pods: false, active: !@data.all_pods?)
      scope_button("All pods", all_pods: true, active: @data.all_pods?)
    end
  end

  # scope_button — switching scope re-anchors at the default window
  # (no expand carried), since the new pool is a fresh neighbourhood.
  def scope_button(label, all_pods:, active:)
    button(
      type: "button",
      data: {
        action: "click->log-analytics#openSurrounding",
        ts: @data.anchor_ts,
        pod: @data.pod,
        all_pods: (all_pods ? "1" : "0")
      },
      class: tokens(
        "inline-flex items-center px-2.5 h-6 text-[11px] font-medium border transition-colors",
        active ? "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2" : "border-transparent text-voodu-text-2 hover:bg-voodu-surface-2"
      )
    ) { label }
  end

  def window_body
    if @data.empty?
      div(class: "px-4 py-10 text-center text-voodu-muted text-[12.5px]") do
        plain "No surrounding lines in the warehouse for this window."
      end

      return
    end

    # Same column grid as the results table (ColumnChrome): wiring the SAME
    # logs-columns config (one storage key) means the operator's hidden +
    # resized columns apply here too, the header is shown, and the columns
    # are resizable. `.la-cols-host` + the overlay give the identical
    # hide-until-ready "Rendering…" treatment.
    #
    # The rows live in their OWN `flex-1 overflow-auto` scroller (same as the
    # results table) so the `position: sticky` column header pins to the top
    # of THIS region, below the fixed context strip — not to the modal body,
    # where it landed behind the strip and vanished on scroll. NOT a
    # logs-columns/log-analytics scroller target: the controller assumes a
    # single results scroller (wrap/jump), and openSurrounding's scrollIntoView
    # finds this scroller as the anchor cell's nearest ancestor on its own.
    div(class: "la-cols-host relative flex-1 min-h-0 flex flex-col bg-voodu-bg-2", data: column_grid_attrs) do
      loading_overlay
      div(class: "flex-1 overflow-auto min-h-0") do
        div(class: "log-list la-list") do
          column_header
          @data.rows.each_with_index do |row, idx|
            render Components::LogAnalytics::Row.new(
              row: row,
              surroundable: false,
              anchor: idx == @data.anchor_index
            )
          end
        end

        load_more
      end
    end
  end

  # load_more — widen the window one step (expand+1 scales the time
  # radius + kept context). Re-fetches + re-injects via openSurrounding,
  # re-centring on the anchor.
  def load_more
    return unless @data.more?

    div(class: "p-2 border-t border-voodu-border") do
      button(
        type: "button",
        data: {
          action: "click->log-analytics#openSurrounding",
          ts: @data.anchor_ts,
          pod: @data.pod,
          all_pods: (@data.all_pods? ? "1" : "0"),
          expand: @data.next_expand
        },
        class: "flex items-center justify-center gap-1.5 w-full px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors"
      ) do
        render Icon::ArrowsPointingOutOutline.new(class: "w-3.5 h-3.5")
        span { "Load more lines" }
      end
    end
  end

  # surrounding_url — the modal's own endpoint for THIS anchor + scope +
  # expand. With `fmt:` it serves the export of the exact batch shown.
  def surrounding_url(**extra)
    logs_analytics_surrounding_path(
      pod: @data.pod,
      ts: @data.anchor_ts,
      all_pods: (@data.all_pods? ? "1" : "0"),
      expand: @data.expand,
      **extra
    )
  end
end
