# frozen_string_literal: true

# The deliveries as a table.
#
# The columns answer the questions asked in order: WHEN did it arrive, WHAT was
# it, what is it ABOUT, and what did we DO. Anything provider-specific stays in
# the row's own detail.
class Components::Deploys::WebhookTable < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    return empty_state if @data.rows.empty?

    div(class: "border border-voodu-border bg-voodu-surface flex flex-col") do
      column_head
      @data.rows.each { |receipt| row(receipt) }
    end
  end

  private

  def column_head
    div(class: "hidden vmd:flex items-center gap-3 px-3 h-8 border-b border-voodu-border " \
               "bg-voodu-surface-2 text-[10.5px] uppercase tracking-wider text-voodu-muted") do
      div(class: "w-5 shrink-0")
      span(class: "w-20 shrink-0") { "Provider" }
      span(class: "w-28 shrink-0") { "Event" }
      span(class: "flex-1 min-w-0") { "Reference" }
      span(class: "w-44 shrink-0") { "Outcome" }
      span(class: "w-24 shrink-0 text-right") { "When" }
    end
  end

  def row(receipt)
    a(href: deploys_webhook_path(id: receipt.id),
      class: "flex flex-col vmd:flex-row vmd:items-center gap-1 vmd:gap-3 px-3 py-2.5 " \
             "no-underline border-b border-voodu-border last:border-b-0 hover:bg-voodu-hover") do
      # The slot is always drawn — see Components::Deploys::DeploymentRow for
      # why a cell that vanishes unaligns every header to its right.
      div(class: "hidden vmd:block w-5 shrink-0") do
        render Components::Deploys::Sender.new(
          login: receipt.sender, avatar: receipt.sender_avatar, url: receipt.sender_url,
          # The row is already a link — see Sender for why a second one here
          # silently breaks the flex row.
          linked: false
        )
      end

      span(class: "vmd:w-20 shrink-0 text-[12px] text-voodu-text-2") { receipt.provider }

      span(class: "vmd:w-28 shrink-0 font-voodu-mono text-[11.5px] text-voodu-text truncate") do
        receipt.event
      end

      span(class: "flex-1 min-w-0 font-voodu-mono text-[11.5px] text-voodu-muted truncate") do
        receipt.reference.presence || "—"
      end

      outcome(receipt)

      span(class: "vmd:w-24 shrink-0 vmd:text-right text-[11px] text-voodu-muted",
        title: receipt.received_at.to_fs(:long)) do
        "#{ActionController::Base.helpers.time_ago_in_words(receipt.received_at)} ago"
      end
    end
  end

  # The label, not the machine name. `no_target` means nothing to somebody
  # reading a list; "No server listed it" is the sentence they need.
  def outcome(receipt)
    span(class: "vmd:w-44 shrink-0") do
      render Components::UI::Badge.new(variant: variant_for(receipt)) { receipt.status_label }
    end
  end

  # Only the three an operator is hunting for are colored. A working
  # installation is a wall of `accepted` and `ignored`, and coloring those
  # makes the two that matter harder to find, not easier.
  def variant_for(receipt)
    case receipt.status
    when "refused_signature", "failed" then :danger
    when "no_target" then :warning
    when "accepted" then :success
    else :neutral
    end
  end

  def empty_state
    div(class: "border border-voodu-border bg-voodu-surface px-3.5 py-8 flex flex-col gap-2 text-center") do
      if @data.filtered?
        p(class: "m-0 text-[12.5px] text-voodu-muted") { "No delivery matches those filters." }
      else
        p(class: "m-0 text-[12.5px] text-voodu-text-2") { "No webhook has arrived yet." }
        p(class: "m-0 text-[12px] text-voodu-muted") do
          plain "If a push should have landed here, check the app's own delivery log — "
          plain "an event that was never subscribed to never reaches us at all."
        end
      end
    end
  end
end
