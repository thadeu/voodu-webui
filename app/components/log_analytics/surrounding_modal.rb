# frozen_string_literal: true

# Components::LogAnalytics::SurroundingModal — the Surrounding Logs
# overlay body. Wraps Components::UI::Modal (size :xl) so it inherits the
# backdrop + scroll-lock + ESC handling. No close_to: the X fires
# modal#close, which dispatches `modal:close`; the log-analytics
# controller catches that (bubbled to the page root) and empties the
# host, tearing the overlay down without a navigation.
#
# Body: a context strip (count + scope toggle + export this batch), then
# the window of Row components in chronological order (anchor highlighted
# + tagged for scroll-into-view), ending in a "Load more" trigger when a
# wider window would reveal more lines.
#
# Export stays IN the modal: the Copy button fetches the export endpoint;
# the Download links carry data-turbo=false so the browser handles the
# attachment with no navigation — neither closes the dialog (they live
# inside it, not on the backdrop).
class Components::LogAnalytics::SurroundingModal < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    render(
      Components::UI::Modal.new(
        title:    "Surrounding logs",
        subtitle: subtitle,
        icon:     :ArrowsPointingOutOutline,
        size:     :xl
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

  def context_strip
    div(class: "sticky top-0 z-10 flex flex-wrap items-center justify-between gap-2 px-4 py-2 border-b border-voodu-border bg-voodu-bg-2") do
      div(class: "text-[11px] text-voodu-muted") do
        if @data.found?
          plain "#{@data.rows.size} lines around the selected line"
        else
          plain "Anchor line not found — showing the nearest window"
        end
      end

      div(class: "flex items-center gap-2") do
        export_cluster
        scope_toggle
      end
    end
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
      type:  "button",
      title: "Copy this batch as #{fmt.upcase}",
      data:  { action: "click->log-analytics#copyExport", export_url: surrounding_url(fmt: fmt) },
      class: export_btn_class
    ) do
      render Icon::ClipboardDocumentOutline.new(class: "w-3 h-3")
      span { label }
    end
  end

  def export_download(label, fmt)
    a(
      href:     surrounding_url(fmt: fmt),
      download: "",
      title:    "Download this batch as #{label}",
      data:     { turbo: false },
      class:    export_btn_class
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
      scope_button("All pods", all_pods: true,  active: @data.all_pods?)
    end
  end

  # scope_button — switching scope re-anchors at the default window
  # (no expand carried), since the new pool is a fresh neighbourhood.
  def scope_button(label, all_pods:, active:)
    button(
      type: "button",
      data: {
        action:   "click->log-analytics#openSurrounding",
        ts:       @data.anchor_ts,
        pod:      @data.pod,
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

    div(class: "bg-voodu-bg-2") do
      @data.rows.each_with_index do |row, idx|
        render Components::LogAnalytics::Row.new(
          row:          row,
          surroundable: false,
          anchor:       idx == @data.anchor_index
        )
      end

      load_more
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
          action:   "click->log-analytics#openSurrounding",
          ts:       @data.anchor_ts,
          pod:      @data.pod,
          all_pods: (@data.all_pods? ? "1" : "0"),
          expand:   @data.next_expand
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
      pod:      @data.pod,
      ts:       @data.anchor_ts,
      all_pods: (@data.all_pods? ? "1" : "0"),
      expand:   @data.expand,
      **extra
    )
  end
end
