# frozen_string_literal: true

# One delivery: what arrived, what we decided, and what it produced.
#
# The payload is shown because it is EVIDENCE — the bytes a provider sent, kept
# so a disagreement about what was delivered can be settled. It is never read
# as instructions: everything the app acted on was re-derived from our own
# records after the signature verified.
class Views::Deploys::Webhook < Views::Deploys::Shell
  def initialize(current_path:, servers: [], current_server: nil, data: nil, **)
    super
    @receipt = data&.receipt
  end

  private

  def tab = :webhooks

  def subtitle = nil

  def breadcrumb
    [
      {label: "Deploys", href: deploys_repositories_path},
      {label: "Webhooks", href: deploys_webhooks_path},
      {label: @receipt.event}
    ]
  end

  def content
    div(class: "flex flex-col gap-4") do
      back_link
      outcome_callout
      facts_card
      produced_card
      payload_card
    end
  end

  def back_link
    a(href: deploys_webhooks_path,
      class: "self-start inline-flex items-center gap-1.5 text-[12px] text-voodu-link no-underline") do
      render Icon::ArrowLeftOutline.new(class: "w-3.5 h-3.5")
      span { "All deliveries" }
    end
  end

  # The outcome first and in plain words, because it is the whole reason
  # somebody opened this row.
  def outcome_callout
    render Components::UI::Callout.new(tone: tone_for, title: @receipt.status_label) do
      span(class: "text-[12.5px] text-voodu-text-2") { explanation }
    end
  end

  def tone_for
    case @receipt.status
    when "refused_signature", "failed" then :danger
    when "no_target" then :warning
    when "accepted" then :success
    else :neutral
    end
  end

  # What the outcome MEANS and what to do about it. The status word alone
  # tells an operator what happened and not what it is their move.
  def explanation
    reason = @receipt.details.is_a?(Hash) ? @receipt.details["reason"] : nil

    case @receipt.status
    when "refused_signature"
      "The HMAC did not match. The secret configured on the provider's side is not " \
        "the one this installation holds — nothing else was read from the request."
    when "no_target"
      "#{reason || "Nothing here lists that repository."} Connect it to a server " \
        "on the Repositories tab and the next push will land."
    when "duplicate"
      "The provider retried a delivery we had already seen. Nothing ran twice."
    when "ignored"
      "We do not act on this event. Accepted so the provider stops retrying it."
    when "accepted"
      "Verified and matched. What it produced is below."
    else
      reason || "No further detail was recorded."
    end
  end

  def facts_card
    render Components::UI::SectionCard.new(title: "Delivery") do
      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-x-6") do
        fact("Provider", @receipt.provider)
        fact("Event", @receipt.event)
        fact("Reference", @receipt.reference.presence)
        fact("Delivery id", @receipt.external_id.presence)
        fact("Received", WebTime.in_zone(@receipt.received_at).strftime("%Y-%m-%d %H:%M:%S"))
      end
    end
  end

  def fact(label, value)
    return if value.blank?

    div(class: "flex flex-col vmd:flex-row vmd:items-baseline gap-0.5 vmd:gap-3 " \
               "px-3.5 py-2 border-b border-voodu-border") do
      span(class: "text-[11px] uppercase tracking-[0.06em] text-voodu-muted vmd:w-28 shrink-0") { label }
      span(class: "text-[12.5px] text-voodu-text-2 font-voodu-mono min-w-0 break-all") { value }
    end
  end

  # What this delivery produced, asked of the CHILDREN — one delivery can fan
  # out to several deployments, which is why the link points this way.
  def produced_card
    deployments = @receipt.deployments.recent.to_a

    return if deployments.empty?

    render Components::UI::SectionCard.new(title: "Produced · #{deployments.size}") do
      div(class: "flex flex-col") do
        deployments.each { |d| render Components::Deploys::DeploymentRow.new(deployment: d) }
      end
    end
  end

  def payload_card
    body = @receipt.payload_hash

    return if body.empty?

    render Components::UI::SectionCard.new(title: "Payload as received") do
      # Rendered from the parsed value, so a commit message full of braces and
      # quotes cannot confuse the colouring. The copy hands back the
      # pretty-printed JSON, which is exactly what is on screen.
      render Components::UI::JsonBlock.new(
        value: body, label: "Copy the payload", max_height: "max-h-[420px]"
      )
    end
  end
end
