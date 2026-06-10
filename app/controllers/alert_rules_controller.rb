# frozen_string_literal: true

# AlertRulesController — CRUD for the operator's alert rules, plus
# pause/resume (`toggle`) and the starter-pack seeder (`defaults`).
# Tenant-scoped so current_island flows through naturally.
#
# Form POSTs are full-page (data-turbo:false, same as Islands /
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
    @rule = current_island.alert_rules.new(
      metric_kind: "cpu", target_kind: "host", comparator: "gte",
      threshold: 90, duration_seconds: 300
    )
    render_form
  end

  def create
    @rule = current_island.alert_rules.new(rule_attributes)

    if @rule.save
      redirect_to alerts_path, notice: "Alert rule #{@rule.name} created."
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
      AlertsLive.broadcast(current_island) if was_firing && !@rule.firing?

      redirect_to alerts_path, notice: "Alert rule #{@rule.name} updated."
    else
      render_form(status: :unprocessable_entity)
    end
  end

  def destroy
    was_firing = @rule.firing?
    @rule.destroy

    # A deleted firing rule must clear the badge — its events
    # cascaded away, so the count just changed under every open tab.
    AlertsLive.broadcast(current_island) if was_firing

    redirect_to alerts_path, notice: "Alert rule removed."
  end

  # Pause/resume without opening the form. Pausing a firing rule
  # resolves its open episode (AlertRule#disable!) — the operator
  # said "stop watching this", keeping the badge red would be a lie.
  def toggle
    if @rule.enabled?
      was_firing = @rule.firing?
      @rule.disable!
      AlertsLive.broadcast(current_island) if was_firing
      redirect_to alerts_path, notice: "Rule #{@rule.name} paused."
    else
      @rule.update!(enabled: true, last_status: nil)
      redirect_to alerts_path, notice: "Rule #{@rule.name} resumed."
    end
  end

  def defaults
    AlertRule.create_defaults!(current_island)
    redirect_to alerts_path, notice: "Default rules created."
  end

  private

  # Scope the lookup to the current island so one island can't
  # address another's rules by id. Stale id → bounce, not 500.
  def set_rule
    @rule = current_island.alert_rules.find_by(id: params[:id])
    redirect_to alerts_path, alert: "Alert rule was not found." if @rule.nil?
  end

  def render_form(status: nil)
    page = AlertsPageData.new(current_island)
    view = Views::AlertRules::Form.new(
      **dashboard_context,
      rule:         @rule,
      targets:      page.targets,
      destinations: page.destinations
    )

    status ? render(view, status: status) : render(view)
  end

  def rule_attributes
    permitted = params.require(:alert_rule)
                      .permit(:name, :metric_kind, :target, :comparator,
                              :threshold, :duration_seconds, alert_destination_ids: [])
    attrs  = permitted.to_h
    target = attrs.delete("target").to_s

    # Drop the empty-string sentinel the form sends so an all-unchecked
    # submit clears the association cleanly (rejecting blank ids).
    if attrs["alert_destination_ids"].is_a?(Array)
      attrs["alert_destination_ids"] = attrs["alert_destination_ids"].reject(&:blank?)
    end

    if target.start_with?("pod|")
      _, scope, name = target.split("|", 3)
      attrs.merge("target_kind" => "pod", "target_scope" => scope, "target_name" => name)
    else
      attrs.merge("target_kind" => "host", "target_scope" => nil, "target_name" => nil)
    end
  end
end
