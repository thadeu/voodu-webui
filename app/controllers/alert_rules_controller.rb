# frozen_string_literal: true

# AlertRulesController — CRUD for the operator's alert rules, plus
# pause/resume (`toggle`) and the starter-pack seeder (`defaults`).
# Server-scoped so current_server flows through naturally.
#
# Form POSTs are full-page (data-turbo:false, same as Servers /
# MetricDashboards): success redirects to /alerts; a validation
# error re-renders the form with inline errors and the entered
# values intact.
#
# The form submits the target as ONE encoded select value —
# `"host"` or `"pod|<scope>|<name>"` — because host-vs-pod is a
# single mutually-exclusive choice to the operator. The split into
# target_kind/scope/name happens here, not in the view or model.
class AlertRulesController < ApplicationController
  before_action :set_rule, only: [:edit, :update, :destroy, :toggle]

  def new
    # Owned by the org (M3); default target = the current server's host.
    @rule = current_org.alert_rules.new(
      server: current_server,
      metric_kind: "cpu", target_kind: "host", comparator: "gte",
      threshold: 90, duration_seconds: 300
    )
    render_form
  end

  def create
    @rule = current_org.alert_rules.new(rule_attributes)

    if @rule.save
      redirect_to return_to_path(alerts_path), notice: "Alert rule #{@rule.name} created."
    else
      render_form(status: :unprocessable_entity)
    end
  end

  def edit
    render_form
  end

  def update
    if @rule.update(rule_attributes)
      # If a firing rule's CONDITION changed, the open episode is now
      # stale (it snapshotted the old threshold/metric/target). Close
      # it and let the evaluator re-open against the new condition.
      was_firing = @rule.firing?
      @rule.clear_episode_on_change!
      AlertsLive.broadcast(current_server) if was_firing && !@rule.firing?

      redirect_to return_to_path(alerts_path), notice: "Alert rule #{@rule.name} updated."
    else
      render_form(status: :unprocessable_entity)
    end
  end

  def destroy
    was_firing = @rule.firing?
    @rule.destroy

    # A deleted firing rule must clear the badge — its events
    # cascaded away, so the count just changed under every open tab.
    AlertsLive.broadcast(current_server) if was_firing

    redirect_to return_to_path(alerts_path), notice: "Alert rule removed."
  end

  # Pause/resume without opening the form. Pausing a firing rule
  # resolves its open episode (AlertRule#disable!) — the operator
  # said "stop watching this", keeping the badge red would be a lie.
  def toggle
    if @rule.enabled?
      was_firing = @rule.firing?
      @rule.disable!
      AlertsLive.broadcast(current_server) if was_firing
      redirect_to return_to_path(alerts_path), notice: "Rule #{@rule.name} paused."
    else
      @rule.update!(enabled: true, last_status: nil)
      redirect_to return_to_path(alerts_path), notice: "Rule #{@rule.name} resumed."
    end
  end

  def defaults
    AlertRule.create_defaults!(current_server)
    # Seeding is only offered from the Rules tab, so default the return there.
    redirect_to return_to_path(alerts_path(tab: "rules")), notice: "Default rules created."
  end

  private

  # Scope the lookup to the ORG so one org can't address another's rules by id
  # (M3). Stale / cross-org id → bounce, not 500.
  def set_rule
    @rule = current_org.alert_rules.find_by(id: params[:id])
    redirect_to return_to_path(alerts_path), alert: "Alert rule was not found." if @rule.nil?
  end

  def render_form(status: nil)
    page = AlertsPageData.new(current_org, current_server)
    view = Views::AlertRules::Form.new(
      # dashboard_context already carries servers: all_servers (== page.servers,
      # both the org's servers) — the form uses it for the layout AND the picker.
      **dashboard_context,
      rule: @rule,
      targets: page.targets,
      destinations: page.destinations,
      # Where cancel/close/save go — the validated origin, or /alerts by default.
      return_to: return_to_path(alerts_path)
    )

    status ? render(view, status: status) : render(view)
  end

  # rule_attributes — decode the form's single encoded target select into
  # server_id (which SERVER, M3) + target_kind + scope/name. The value shapes:
  #   "host|<server_id>"                 → a server's host
  #   "pod|<server_id>|<scope>|<name>"   → a pod on that server
  # server_id resolved WITHIN the org (the guard) so a forged id for another
  # org's server can't be targeted — falls back to the current server.
  def rule_attributes
    permitted = params.require(:alert_rule)
      .permit(:name, :metric_kind, :target, :comparator,
        :threshold, :duration_seconds, alert_destination_ids: [])
    attrs = permitted.to_h
    target = attrs.delete("target").to_s

    # Drop the empty-string sentinel the form sends so an all-unchecked
    # submit clears the association cleanly (rejecting blank ids).
    if attrs["alert_destination_ids"].is_a?(Array)
      attrs["alert_destination_ids"] = attrs["alert_destination_ids"].reject(&:blank?)
    end

    kind, server_id, scope, name = target.split("|", 4)
    attrs["server_id"] = org_server_id(server_id)

    if kind == "pod"
      attrs.merge("target_kind" => "pod", "target_scope" => scope, "target_name" => name)
    else
      attrs.merge("target_kind" => "host", "target_scope" => nil, "target_name" => nil)
    end
  end

  # org_server_id — an server id from the encoded target, kept only if it's a
  # server IN the org (the isolation guard); otherwise the current server. The
  # model re-validates server ∈ org, so a forged id can never save.
  def org_server_id(id)
    return current_server&.id if id.blank?

    current_org.servers.where(id: id).pick(:id) || current_server&.id
  end
end
