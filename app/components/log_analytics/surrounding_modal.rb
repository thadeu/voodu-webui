# frozen_string_literal: true

# Components::LogAnalytics::SurroundingModal — the Surrounding Logs
# overlay body. Wraps Components::UI::Modal (size :lg) so it inherits the
# backdrop + scroll-lock + ESC handling. No close_to: the X fires
# modal#close, which dispatches `modal:close`; the log-analytics
# controller catches that (bubbled to the page root) and empties the
# host, tearing the overlay down without a navigation.
#
# Body: a context strip (pod + anchor timestamp + a This pod / All pods
# scope toggle), then the window of Row components in chronological
# order, with the anchor row highlighted + tagged so the controller
# scrolls it into view on open.
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

  # context_strip — scope toggle. Re-fetches the same anchor with/without
  # the all-pods widening; the controller reuses #openSurrounding, so the
  # currently-open modal is replaced by the new scope's window.
  def context_strip
    div(class: "sticky top-0 z-10 flex items-center justify-between gap-2 px-4 py-2 border-b border-voodu-border bg-voodu-bg-2") do
      div(class: "text-[11px] text-voodu-muted") do
        if @data.found?
          plain "#{@data.rows.size} lines around the selected line"
        else
          plain "Anchor line not found — showing the nearest window"
        end
      end

      scope_toggle
    end
  end

  def scope_toggle
    div(class: "inline-flex items-center gap-px p-[2px] border border-voodu-border bg-voodu-surface") do
      scope_button("This pod", all_pods: false, active: !@data.all_pods?)
      scope_button("All pods", all_pods: true,  active: @data.all_pods?)
    end
  end

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
    end
  end
end
