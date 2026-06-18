# frozen_string_literal: true

require "test_helper"

class AlertDestinationsControllerTest < ActionDispatch::IntegrationTest
  fixtures :islands

  PUBLIC = "93.184.216.34"

  setup do
    @island = islands(:alpha)
    @key = @island.key
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  test "new renders the modal form" do
    get new_alert_destination_path(tenant_key: @key)

    assert_response :success
    assert_includes response.body, "New destination"
    assert_includes response.body, "destination-form"
  end

  test "create persists an encrypted webhook destination" do
    assert_difference("AlertDestination.count", 1) do
      post alert_destinations_path(tenant_key: @key), params: {
        alert_destination: {
          name: "ops", kind: "webhook", endpoint: "https://#{PUBLIC}/h",
          on_firing: "1", on_resolved: "0", enabled: "1"
        }
      }
    end

    d = AlertDestination.order(:id).last
    assert_equal "webhook", d.kind
    assert_equal "https://#{PUBLIC}/h", d.endpoint
    assert_not d.on_resolved
    assert_redirected_to alerts_path(tenant_key: @key, tab: "destinations")
  end

  test "create persists a custom auth header (name + encrypted value)" do
    post alert_destinations_path(tenant_key: @key), params: {
      alert_destination: {
        name: "zap", kind: "webhook", endpoint: "https://#{PUBLIC}/z",
        secret_header: "x-zapier-key", secret: "zap-abc", on_firing: "1"
      }
    }

    d = AlertDestination.order(:id).last
    assert_equal "x-zapier-key", d.secret_header
    assert_equal "zap-abc", d.secret
    assert_equal({"x-zapier-key" => "zap-abc"}, d.auth_header)
  end

  test "edit keeps the secret value when blank but clears the header name when emptied" do
    d = @island.alert_destinations.create!(
      name: "hdr", kind: "webhook", endpoint: "https://#{PUBLIC}/h",
      secret_header: "Authorization", secret: "Bearer keep"
    )

    # The URL is pre-filled in the real form, so it's re-submitted.
    patch alert_destination_path(tenant_key: @key, id: d.id), params: {
      alert_destination: {name: "hdr", endpoint: "https://#{PUBLIC}/h",
                          secret_header: "", secret: "", on_firing: "1", on_resolved: "1"}
    }

    d.reload
    assert_equal "Bearer keep", d.secret, "blank value keeps the stored credential"
    assert_nil d.secret_header.presence, "blank header name clears it (not secret)"
    assert_equal({}, d.auth_header)
  end

  test "create persists a webhook body template" do
    post alert_destinations_path(tenant_key: @key), params: {
      alert_destination: {
        name: "tmpl", kind: "webhook", endpoint: "https://#{PUBLIC}/h",
        body_template: '{"text":"{{rule}} {{state}}"}', on_firing: "1"
      }
    }

    d = AlertDestination.order(:id).last
    assert d.custom_body?
    assert_equal '{"text":"{{rule}} {{state}}"}', d.body_template
  end

  test "invalid JSON body template re-renders 422" do
    post alert_destinations_path(tenant_key: @key), params: {
      alert_destination: {
        name: "bad", kind: "webhook", endpoint: "https://#{PUBLIC}/h",
        body_template: "{not json", on_firing: "1"
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "valid JSON"
  end

  test "invalid create (non-http endpoint) re-renders with the inline error" do
    post alert_destinations_path(tenant_key: @key), params: {
      alert_destination: {name: "bad", endpoint: "ftp://evil.example/x", on_firing: "1"}
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "http(s) URL"
  end

  test "edit re-saves the (pre-filled, revealable) endpoint" do
    d = @island.alert_destinations.create!(
      name: "keep", kind: "webhook", endpoint: "https://#{PUBLIC}/keep"
    )

    patch alert_destination_path(tenant_key: @key, id: d.id), params: {
      alert_destination: {name: "keep2", endpoint: "https://#{PUBLIC}/new", on_firing: "1", on_resolved: "1"}
    }

    d.reload
    assert_equal "keep2", d.name
    assert_equal "https://#{PUBLIC}/new", d.endpoint
  end

  test "test action delivers and records ok" do
    d = @island.alert_destinations.create!(name: "t", kind: "webhook", endpoint: "https://#{PUBLIC}/t")
    stub = stub_request(:post, "https://#{PUBLIC}/t").to_return(status: 200)

    post test_alert_destination_path(tenant_key: @key, id: d.id)

    assert_requested stub
    assert_equal "ok", d.reload.last_status
    assert_redirected_to alerts_path(tenant_key: @key, tab: "destinations")
  end

  test "test action records failure on error" do
    d = @island.alert_destinations.create!(name: "t", kind: "webhook", endpoint: "https://#{PUBLIC}/t")
    stub_request(:post, "https://#{PUBLIC}/t").to_return(status: 500)

    post test_alert_destination_path(tenant_key: @key, id: d.id)

    assert_equal "failed", d.reload.last_status
    assert_redirected_to alerts_path(tenant_key: @key, tab: "destinations")
  end

  test "destroy removes the destination" do
    d = @island.alert_destinations.create!(name: "gone", kind: "webhook", endpoint: "https://#{PUBLIC}/g")

    assert_difference("AlertDestination.count", -1) do
      delete alert_destination_path(tenant_key: @key, id: d.id)
    end
  end

  test "one island cannot address another island's destination" do
    d = @island.alert_destinations.create!(name: "mine", kind: "webhook", endpoint: "https://#{PUBLIC}/m")
    other = islands(:beta).key

    delete alert_destination_path(tenant_key: other, id: d.id)

    assert_redirected_to alerts_path(tenant_key: other, tab: "destinations")
    assert AlertDestination.exists?(d.id), "cross-tenant destroy must not delete it"
  end
end
