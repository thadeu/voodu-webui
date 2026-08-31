# frozen_string_literal: true

require "test_helper"

# The plan badge in the topbar — which tier this installation runs on, visible
# from wherever the operator happens to be.
#
# Two words carry the answer, because that is the question people ask. The
# states underneath are five: the extra three are exceptions somebody has to act
# on, and they are told apart by colour and tooltip rather than by inventing
# labels nobody would recognise. What each one must NOT do is lie about whether
# the entitlements are currently granted — that is the whole point of the badge.
class LicenseBadgeTest < ActionDispatch::IntegrationTest
  setup do
    @configured = Rails.application.config.x.license
    sign_in_as(email: users(:owner).email)
  end

  teardown { Rails.application.config.x.license = @configured }

  def a_page
    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_response :success
  end

  def stub_license(status, customer: "acme-corp", expires: 30.days.from_now)
    Rails.application.config.x.license = LicenseToken.new(
      status: status, claims: {"sub" => customer, "exp" => expires.to_i}
    )
  end

  def badge
    css_select("header span[title]").find { |node| node["title"].to_s.include?("icen") }
  end

  test "the free tier is named on every page, not only on the licence screen" do
    Rails.application.config.x.license = LicenseToken.new(status: :none)

    a_page

    assert_equal "Free", badge.text.strip
    assert_match(/no licence installed/, badge["title"])
  end

  test "a valid licence says Licensed and names the customer" do
    stub_license(:valid)

    a_page

    assert_equal "Licensed", badge.text.strip
    assert_match(/acme-corp/, badge["title"])
  end

  # Grace still GRANTS the entitlements, so calling it Free would be the lie.
  # The tooltip and the amber are what say "act on this".
  test "a licence in grace still says Licensed" do
    stub_license(:grace, expires: 2.days.ago)

    a_page

    assert_equal "Licensed", badge.text.strip
    assert_match(/expired/, badge["title"])
    assert_match(/amber/, badge["class"])
  end

  # Lapsed does NOT grant them, so the opposite lie is the one to avoid: this
  # installation really is on the free tier now.
  test "a lapsed licence says Free" do
    stub_license(:lapsed, expires: 90.days.ago)

    a_page

    assert_equal "Free", badge.text.strip
    assert_match(/lapsed/, badge["title"])
    assert_match(/red/, badge["class"])
  end

  test "a licence that cannot be verified says Free rather than claiming a plan" do
    Rails.application.config.x.license = LicenseToken.new(status: :invalid, reason: "bad signature")

    a_page

    assert_equal "Free", badge.text.strip
    assert_match(/could not be verified/, badge["title"])
  end

  # The badge renders on EVERY page, and resolving a licence verifies an RSA
  # signature and queries the database. It reads what the controller already
  # memoised, so adding it must not have put a second resolution on every
  # request in the app.
  test "the badge costs no extra licence resolution" do
    Rails.application.config.x.license = nil
    calls = 0
    counter = Module.new do
      define_method(:current) do |*args, **opts|
        calls += 1
        super(*args, **opts)
      end
    end
    LicenseToken.singleton_class.prepend(counter)

    a_page

    assert_equal 1, calls, "expected one licence resolution per request, got #{calls}"
  end

  # At 360px the bar already holds a menu button, the server name, a search
  # button, a theme button and an avatar. The badge steps out there — and it has
  # to be the WRAPPER that hides, not the badge: Badge's own class carries
  # `inline-flex`, `.inline-flex` is emitted after `.hidden` in the compiled
  # sheet, so a `hidden` written onto the badge itself loses the cascade and the
  # badge stays visible. Verified against the built CSS, not assumed.
  test "the badge steps out of a narrow bar, and hides from a wrapper to do it" do
    Rails.application.config.x.license = LicenseToken.new(status: :none)

    a_page

    wrapper = css_select("header div.hidden").find { |node| node.to_s.include?(">Free<") }

    assert wrapper, "the badge is not inside an element that hides on mobile"
    assert_match(/vmd:(block|flex)/, wrapper["class"],
      "the wrapper must reveal the badge at the breakpoint")
    assert_not_includes badge["class"], "hidden",
      "hidden on the badge itself loses to its own inline-flex"
  end

  # It sits in a row of 32px controls — the search box, the theme button — and a
  # 20px pill among them reads as misaligned rather than as emphasis.
  test "the badge stands at the height of the controls beside it" do
    Rails.application.config.x.license = LicenseToken.new(status: :none)

    a_page

    assert_includes badge["class"], "h-8"
  end

  # The two menu rows answer the question that makes someone open them.
  test "the account menu names the plan beside the licence row" do
    Rails.application.config.x.license = LicenseToken.new(status: :none)

    a_page

    assert_select "a[href='/ops/license'] span", text: "free"
  end

  test "a licensed installation says enterprise on that row" do
    stub_license(:valid)

    a_page

    assert_select "a[href='/ops/license'] span", text: "enterprise"
  end

  # Grace still grants the LICENSED table, so the row must not drop to free
  # while the limits in force are still the licensed ones.
  test "a licence in grace still reads enterprise on that row" do
    stub_license(:grace, expires: 2.days.ago)

    a_page

    assert_select "a[href='/ops/license'] span", text: "enterprise"
  end

  test "a lapsed licence reads free on that row" do
    stub_license(:lapsed, expires: 90.days.ago)

    a_page

    assert_select "a[href='/ops/license'] span", text: "free"
  end

  test "the sign-in row names its provider" do
    Rails.application.config.x.license = LicenseToken.new(status: :none)

    a_page

    assert_select "a[href='/ops/sso'] span", text: "clowk"
  end
end
