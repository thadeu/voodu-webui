# frozen_string_literal: true

require "test_helper"

# The paid option, offered beside the free one on both installation screens.
#
# The rule that matters is not that the pitch appears — it is that it appears
# ONLY where there is something to sell. Advertising Enterprise to somebody
# holding an Enterprise licence reads as a product that does not know what it
# sold, and advertising sign-in to an installation that already asks for it is
# the same mistake with a different noun.
class UpsellTest < ActionDispatch::IntegrationTest
  setup do
    @configured = Rails.application.config.x.license
    @clowk = Rails.application.config.x.clowk_enabled
    sign_in_as(email: users(:owner).email)
  end

  teardown do
    Rails.application.config.x.license = @configured
    Rails.application.config.x.clowk_enabled = @clowk
  end

  def free_tier
    Rails.application.config.x.license = LicenseToken.new(status: :none)
  end

  def licensed(status = :valid, expires: 30.days.from_now)
    Rails.application.config.x.license = LicenseToken.new(
      status: status, claims: {"sub" => "acme-corp", "exp" => expires.to_i}
    )
  end

  # ── Licence screen ────────────────────────────────────────────────

  test "the free tier is told the paid tier exists" do
    free_tier

    get ops_license_path

    assert_response :success
    assert_select "a[href=?]", "https://voodu.clowk.in/license/enterprise"
  end

  test "the pitch offers a way to talk to a person, not only a page" do
    free_tier

    get ops_license_path

    assert_select "a[href^=?]", "mailto:hello@clowk.in"
  end

  # Someone who already bought is not a prospect.
  test "a licensed installation is not advertised at" do
    licensed

    get ops_license_path

    assert_select "a[href=?]", "https://voodu.clowk.in/license/enterprise", false
  end

  # Grace still GRANTS the licensed entitlements. The expiry on the left is what
  # needs acting on; a purchase pitch would be aiming at the wrong lever.
  test "a licence in grace is not advertised at either" do
    licensed(:grace, expires: 2.days.ago)

    get ops_license_path

    assert_select "a[href=?]", "https://voodu.clowk.in/license/enterprise", false
  end

  # Lapsed means the entitlements are gone — this installation really is back on
  # the free tier, and renewing is exactly what it should be offered.
  test "a lapsed licence is offered the way back" do
    licensed(:lapsed, expires: 90.days.ago)

    get ops_license_path

    assert_select "a[href=?]", "https://voodu.clowk.in/license/enterprise"
  end

  # ── Sign-in screen ────────────────────────────────────────────────

  test "an installation that already signs people in is not sold sign-in" do
    Rails.application.config.x.clowk_enabled = true

    get ops_sso_path

    assert_select "a[href=?]", "https://clowk.in", false
  end

  # The columns are a layout, not two pages: the thing the operator came for
  # must come first in the source, so a phone shows it before the pitch.
  test "the settings come before the pitch in the document" do
    free_tier

    get ops_license_path

    plan = response.body.index("Activate a licence")
    pitch = response.body.index("Run it without the limits")

    assert plan, "the activation form is missing"
    assert pitch, "the pitch is missing"
    assert plan < pitch, "the pitch renders before the form, so it would come first on a phone"
  end

  # Every link in the pitch leaves the app, and target=_blank without
  # rel=noopener hands the opened page a handle back on this one.
  test "the outbound link cannot reach back into this page" do
    free_tier

    get ops_license_path

    assert_select "a[href='https://voodu.clowk.in/license/enterprise'][rel~=?]", "noopener"
  end

  # ── The price ─────────────────────────────────────────────────────

  # A pitch with no figure makes the reader ask, and asking is where most of
  # them stop. "From" is load-bearing: it says this is an entry price, and a
  # card that quotes one without saying so is a thing a buyer holds against you.
  test "the sign-in pitch names its entry price" do
    Rails.application.config.x.clowk_enabled = false

    get ops_sso_path

    assert_response :success
    assert_select "p", text: /From\s+\$9\s+per month/
  end

  # The free line comes FIRST, and it is not decoration: an operator can have
  # this for nothing at the size most self-hosted installations are. Opening
  # with $9 would quote a price for something they do not have to buy.
  test "the pitch leads with what costs nothing" do
    Rails.application.config.x.clowk_enabled = false

    get ops_sso_path

    assert_select "p", text: /Free to create an account, for one app/
  end

  test "the free line is placed above the figure, not after it" do
    Rails.application.config.x.clowk_enabled = false

    get ops_sso_path

    # Fragments that survive the markup: the amounts sit in their own spans, so
    # "Free to create…" is not contiguous in the source even though it reads
    # that way. assert_select above already covers the rendered wording.
    free = response.body.index("to create an account, for one app")
    paid = response.body.index("per month if you need more")

    assert free && paid, "both price lines must render"
    assert free < paid, "the paid figure renders first, so it reads as the price"
  end

  # The amount is mono, like every other number in this app.
  test "the amount is set in the mono face the rest of the numbers use" do
    Rails.application.config.x.clowk_enabled = false

    get ops_sso_path

    assert_select "span.font-voodu-mono", text: "$9"
  end

  # An outbound link to a product the operator has not heard of should say where
  # it goes before they click it, not only in the status bar.
  test "the action names where it leads" do
    Rails.application.config.x.clowk_enabled = false

    get ops_sso_path

    assert_select "a[href=?]", "https://clowk.in", text: /clowk\.in/
  end

  # The price belongs to the pitch, so it leaves with it.
  test "an installation that already signs people in sees no price" do
    Rails.application.config.x.clowk_enabled = true

    get ops_sso_path

    assert_select "p", text: /per month/, count: 0
  end

  # ── The second way in ─────────────────────────────────────────────

  # The marketing page is the right first stop for someone meeting Clowk on
  # this screen, and the wrong one for someone who has already decided and just
  # wants the key the form beside it is asking for.
  test "the pitch offers a direct route to sign-up as well as to the pitch" do
    Rails.application.config.x.clowk_enabled = false

    get ops_sso_path

    assert_select "a[href=?]", "https://app.clowk.in/", text: /create a new account/
  end

  test "the direct route cannot reach back into this page either" do
    Rails.application.config.x.clowk_enabled = false

    get ops_sso_path

    assert_select "a[href='https://app.clowk.in/'][rel~=?]", "noopener"
  end

  # Two filled controls of equal weight would make the reader choose before
  # reading either. These are not equal: one explains, the other commits.
  test "the direct route is a quiet link, not a second filled button" do
    Rails.application.config.x.clowk_enabled = false

    get ops_sso_path

    assert_select "a[href='https://app.clowk.in/']" do |links|
      assert_not_includes links.first["class"], "bg-voodu-btn-accent",
        "the alternate route is competing with the primary action"
    end
  end

  # It belongs to the pitch, so it leaves with it.
  test "an installation that already signs people in sees no sign-up link" do
    Rails.application.config.x.clowk_enabled = true

    get ops_sso_path

    assert_select "a[href=?]", "https://app.clowk.in/", false
  end
end
