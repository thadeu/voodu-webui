# frozen_string_literal: true

# AlertDestinationsController — CRUD for shared notification targets,
# plus a synchronous `test` probe. Tenant-scoped; same full-page
# modal-form pattern as AlertRulesController (data-turbo:false POST,
# redirect on success / 422 re-render on validation error).
#
# Secrets (endpoint URL, secret) are encrypted. On edit, a blank
# field KEEPS the stored value — same convention as the island PAT in
# IslandsController#update, so the operator never has to re-paste a
# webhook URL to change a toggle.
class AlertDestinationsController < ApplicationController
  before_action :set_destination, only: [:edit, :update, :destroy, :test]

  def new
    @destination = current_island.alert_destinations.new(
      kind: "webhook", on_firing: true, on_resolved: true, enabled: true
    )
    render_form
  end

  def create
    @destination = current_island.alert_destinations.new(destination_attributes)

    if @destination.save
      redirect_to alerts_path(tab: "destinations"), notice: "Destination #{@destination.name} created."
    else
      render_form(status: :unprocessable_entity)
    end
  end

  def edit
    render_form
  end

  def update
    if @destination.update(destination_attributes)
      redirect_to alerts_path(tab: "destinations"), notice: "Destination #{@destination.name} updated."
    else
      render_form(status: :unprocessable_entity)
    end
  end

  def destroy
    @destination.destroy
    redirect_to alerts_path(tab: "destinations"), notice: "Destination removed."
  end

  # Synchronous probe — POST a sample firing payload so the operator
  # gets immediate ✓/✗ feedback while configuring. Blocks briefly
  # (WebhookClient's 10s timeout); fine for an operator-initiated
  # one-off.
  def test
    WebhookClient.post(
      @destination.endpoint, AlertPayload.for(sample_event, "firing", @destination),
      headers: @destination.auth_header
    )
    @destination.update_columns(last_delivered_at: Time.current, last_status: "ok", last_error: nil)
    redirect_to alerts_path(tab: "destinations"), notice: "Test delivered to #{@destination.name}."
  rescue WebhookClient::Error => e
    @destination.update_columns(last_status: "failed", last_error: e.message.first(240))
    redirect_to alerts_path(tab: "destinations"), alert: "Test to #{@destination.name} failed: #{e.message}"
  end

  private

  def set_destination
    @destination = current_island.alert_destinations.find_by(id: params[:id])
    redirect_to alerts_path(tab: "destinations"), alert: "Destination was not found." if @destination.nil?
  end

  def render_form(status: nil)
    view = Views::AlertDestinations::Form.new(**dashboard_context, destination: @destination)

    status ? render(view, status: status) : render(view)
  end

  def destination_attributes
    attrs = params.require(:alert_destination)
                  .permit(:name, :endpoint, :secret, :secret_header,
                          :body_template, :on_firing, :on_resolved, :enabled)
                  .to_h

    # Single kind today; force it rather than trusting the form.
    attrs["kind"] = "webhook"

    # Blank ENCRYPTED secret on edit means "keep the stored value" —
    # never overwrite a credential with an empty string just because
    # the operator left the masked field untouched. The URL field is
    # pre-filled (revealable via the eye), so a blank there is a
    # deliberate clear and surfaces the presence error.
    attrs.delete("secret") if @destination&.persisted? && attrs["secret"].blank?
    attrs
  end

  # A non-persisted event carrying representative values, so the test
  # payload looks like a real one without writing history.
  def sample_event
    AlertEvent.new(
      island:       current_island,
      state:        "firing",
      started_at:   Time.current,
      threshold:    90,
      rule_name:    "Test alert",
      metric_kind:  "cpu",
      target_label: "host #{current_island.name}",
      peak_value:   95.0,
      last_value:   95.0
    )
  end
end
