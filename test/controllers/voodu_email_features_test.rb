# frozen_string_literal: true

require "test_helper"

# The emails exist only where a 1billion key does: our cloud console. A
# self-hosted install has none, and every one of these paths stays as it was.
class VooduEmailFeaturesTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  fixtures :orgs, :servers, :users, :org_memberships

  ACME = "acmeorg1"

  setup { @key = servers(:alpha).key }

  test "an invitation is emailed when mail is on" do
    Mailing.stub(:enabled?, true) do
      assert_enqueued_emails 1 do
        post org_members_path(org_id: ACME), params: {email: "new@example.com", role: "member"}
      end
    end

    assert_match "sent to new@example.com", flash[:notice]
  end

  test "an invitation is only a link when mail is off" do
    Mailing.stub(:enabled?, false) do
      assert_no_enqueued_emails do
        post org_members_path(org_id: ACME), params: {email: "new@example.com", role: "member"}
      end
    end

    assert_match "copy the link", flash[:notice]
  end

  test "an email destination is offered only when mail is on" do
    Mailing.stub(:enabled?, true) do
      get new_alert_destination_path(server_key: @key, kind: "email")
    end

    assert_response :success
    assert_select "input[name='alert_destination[recipient_ids][]'][value=?]", users(:contractor).id
    assert_select "input[name='alert_destination[recipient_ids][]'][value=?]", users(:invitee).id, count: 0

    Mailing.stub(:enabled?, false) do
      get new_alert_destination_path(server_key: @key, kind: "email")
    end

    assert_select "input[name='alert_destination[recipient_ids][]']", count: 0
  end

  test "an email destination keeps the chosen org members" do
    Mailing.stub(:enabled?, true) do
      post alert_destinations_path(server_key: @key), params: {
        alert_destination: {name: "team", kind: "email", recipient_ids: ["", users(:owner).id, users(:outsider).id], on_firing: "1"}
      }
    end

    destination = AlertDestination.order(:id).last

    assert_equal "email", destination.kind
    assert_equal [users(:owner).email], destination.recipients
    assert_redirected_to alerts_path(server_key: @key, tab: "destinations")
  end

  test "an email destination needs someone to tell" do
    Mailing.stub(:enabled?, true) do
      post alert_destinations_path(server_key: @key), params: {alert_destination: {name: "nobody", kind: "email", recipient_ids: [""], on_firing: "1"}}
    end

    assert_response :unprocessable_entity
  end

  test "Email us opens a contact form that writes to support" do
    Mailing.stub(:enabled?, true) do
      unlicensed { get ops_license_path }

      assert_select "a[href^='/ops/contact']", text: "Email us"

      get ops_contact_path

      assert_response :success
      assert_select "form[action=?] textarea[name=message]", ops_contact_path

      assert_enqueued_emails 1 do
        post ops_contact_path, params: {message: " We want Enterprise "}
      end
    end

    assert_redirected_to ops_license_path
    assert_match "Thanks", flash[:notice]
  end

  test "an empty contact message is asked again" do
    Mailing.stub(:enabled?, true) do
      assert_no_enqueued_emails { post ops_contact_path, params: {message: " "} }
    end

    assert_redirected_to ops_contact_path
  end

  private

  # The Enterprise card is shown only to an installation without a license.
  def unlicensed
    licensed = Rails.application.config.x.license
    Rails.application.config.x.license = LicenseToken.new(status: :none, claims: {})

    yield
  ensure
    Rails.application.config.x.license = licensed
  end
end
