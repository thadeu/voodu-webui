# frozen_string_literal: true

require "test_helper"

# Members belongs to the org, and has to be reachable before any server exists.
#
# The sidebar derived everything from the SELECTED SERVER — the org id it built
# hrefs from, the org id the active check compared, and the org the capability
# check asked about — and the whole Org group was nested inside "is a server
# selected?". A brand new account has no server, so its owner landed on
# /servers with a sidebar holding one item: License.
#
# The cost was the entire invitation flow, and it did not look like a failure.
# There was no refusal to read and no error to search for; the door simply was
# not drawn. Reported as "I invite a member and nothing appears".
class OrgNavWithoutAServerTest < ActionDispatch::IntegrationTest
  HOSTED = LicenseToken.new(
    status: :valid,
    claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"}
  )

  setup do
    @installed = Rails.application.config.x.license
    Rails.application.config.x.license = HOSTED

    @user = User.create!(email: "brand.new@example.com", email_verified: true)
    PersonalWorkspace.ensure_for(@user, license: HOSTED)
    @org = @user.reload.active_orgs.sole

    sign_in_as(email: @user.email)
  end

  teardown { Rails.application.config.x.license = @installed }

  def sidebar_hrefs
    css_select("nav a").map { |a| a["href"] }
  end

  test "an owner with no servers can still reach Members from the sidebar" do
    get "/#{@org.short_id}/servers"

    assert_response :success
    assert_includes sidebar_hrefs, "/#{@org.short_id}/members"
  end

  test "and the link actually opens, rather than being drawn and refused" do
    get "/#{@org.short_id}/members"

    assert_response :success
  end

  # The other half: per-server items still need a server. Drawing Metrics with
  # nothing to point it at would be the same defect in the other direction.
  test "the per-server items stay away until there is a server" do
    get "/#{@org.short_id}/servers"

    assert(sidebar_hrefs.none? { |href| href.to_s.include?("/metrics") })
    assert(sidebar_hrefs.none? { |href| href.to_s.include?("/alerts") })
  end

  test "and come back once one is selected" do
    server = servers(:alpha)
    orgs(:acme).memberships.create!(user: @user, role: :owner, status: :active)

    get server_root_path(org_id: orgs(:acme).short_id, server_key: server.key)

    assert_response :success
    assert(sidebar_hrefs.any? { |href| href.to_s.include?("/metrics") })
  end

  # A member cannot invite, so the door is not drawn for them — an absence
  # here is correct, which is exactly why the owner's absence was hard to spot.
  test "a member sees no Members link, because they may not invite" do
    guest = User.create!(email: "guest.only@example.com", email_verified: true)
    @org.memberships.create!(user: guest, role: :member, status: :active)
    sign_out
    sign_in_as(email: guest.email)

    get "/#{@org.short_id}/servers"

    assert_response :success
    assert_not_includes sidebar_hrefs, "/#{@org.short_id}/members"
  end
end
