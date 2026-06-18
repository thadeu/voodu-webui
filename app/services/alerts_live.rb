# frozen_string_literal: true

# AlertsLive — pushes alert state changes to every open browser tab.
# Called on each fire/resolve transition (AlertEvaluator) and on
# operator actions that change firing state (pause, delete).
#
# Two signals per broadcast:
#
#   1. Badge refresh — the sidebar's collapsed dot + expanded pill,
#      sent over the EXISTING `island-state-#{id}` channel (the
#      sidebar already subscribes to it for status dots — no new
#      subscription needed). `update` not `replace`, same reasoning
#      as StateSyncIslandJob#broadcast_status_change: replace would
#      remove the id-bearing wrapper and orphan every later
#      broadcast.
#
#   2. `alerts_tick` action on `alerts-#{id}` — the /alerts page
#      subscribes and reloads its `alerts-live` turbo-frame, so the
#      firing cards / rules table / history update without the
#      operator touching anything.
#
# Broadcast failures are logged-and-swallowed: a dead cable must
# never fail the evaluation job (state is already committed; the
# next page render shows the truth regardless).
class AlertsLive
  def self.broadcast(island)
    count = AlertRule.firing_count_for(island.id)

    Turbo::StreamsChannel.broadcast_update_to(
      "island-state-#{island.id}",
      target: "alerts-badge-dot-#{island.id}",
      html: Components::Alerts::NavBadge.new(count: count, variant: :dot).call
    )

    Turbo::StreamsChannel.broadcast_update_to(
      "island-state-#{island.id}",
      target: "alerts-badge-pill-#{island.id}",
      html: Components::Alerts::NavBadge.new(count: count, variant: :pill).call
    )

    Turbo::StreamsChannel.broadcast_action_to("alerts-#{island.id}", action: :alerts_tick)
  rescue => e
    Rails.logger.warn(
      "alerts-live broadcast island=#{island.key} failed: #{e.class}: #{e.message}"
    )
  end
end
