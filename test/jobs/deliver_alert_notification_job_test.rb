# frozen_string_literal: true

require "test_helper"

class DeliverAlertNotificationJobTest < ActiveJob::TestCase
  fixtures :orgs, :islands

  PUBLIC = "93.184.216.34"

  setup do
    @island = islands(:alpha)
    @rule = @island.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    @event = @rule.alert_events.create!(
      island: @island, state: "firing", started_at: 2.minutes.ago,
      threshold: 90, rule_name: @rule.name, metric_kind: "cpu",
      target_label: @rule.target_label, peak_value: 95, last_value: 95
    )
    @dest = @island.org.alert_destinations.create!(
      name: "hook", kind: "webhook", endpoint: "https://#{PUBLIC}/h"
    )
  end

  test "successful POST records last_status ok" do
    stub = stub_request(:post, "https://#{PUBLIC}/h").to_return(status: 200)

    DeliverAlertNotificationJob.perform_now(@event.id, @dest.id, "firing")

    assert_requested stub
    @dest.reload
    assert_equal "ok", @dest.last_status
    assert_not_nil @dest.last_delivered_at
    assert_nil @dest.last_error
  end

  test "sends the destination's custom auth header" do
    @dest.update!(secret_header: "x-api-key", secret: "k-123")
    stub = stub_request(:post, "https://#{PUBLIC}/h")
      .with(headers: {"x-api-key" => "k-123"})
      .to_return(status: 200)

    DeliverAlertNotificationJob.perform_now(@event.id, @dest.id, "firing")

    assert_requested stub
  end

  test "4xx is recorded and discarded — no retry enqueued" do
    stub_request(:post, "https://#{PUBLIC}/h").to_return(status: 400)

    assert_no_enqueued_jobs do
      DeliverAlertNotificationJob.perform_now(@event.id, @dest.id, "firing")
    end

    @dest.reload
    assert_equal "failed", @dest.last_status
    assert @dest.last_error.present?
  end

  test "5xx is recorded and retried — a retry is enqueued" do
    stub_request(:post, "https://#{PUBLIC}/h").to_return(status: 503)

    assert_enqueued_jobs 1, only: DeliverAlertNotificationJob do
      DeliverAlertNotificationJob.perform_now(@event.id, @dest.id, "firing")
    end

    assert_equal "failed", @dest.reload.last_status
  end

  test "webhook with a body template POSTs the rendered JSON verbatim" do
    @dest.update!(body_template: '{"msg":"{{rule}} {{state}}"}')
    stub = stub_request(:post, "https://#{PUBLIC}/h")
      .with(body: '{"msg":"cpu firing"}')
      .to_return(status: 200)

    DeliverAlertNotificationJob.perform_now(@event.id, @dest.id, "firing")

    assert_requested stub
  end

  test "disabled destination is a no-op" do
    @dest.update!(enabled: false)
    DeliverAlertNotificationJob.perform_now(@event.id, @dest.id, "firing")

    assert_not_requested :post, "https://#{PUBLIC}/h"
    assert_nil @dest.reload.last_status
  end

  test "missing event or destination is a no-op" do
    assert_nothing_raised do
      DeliverAlertNotificationJob.perform_now(-1, @dest.id, "firing")
      DeliverAlertNotificationJob.perform_now(@event.id, -1, "firing")
    end
  end
end
