# frozen_string_literal: true

require "test_helper"

# Per-account plans, which exist only on the hosted service.
#
# The installation licence answers "what is this box"; a plan answers "what did
# this customer buy". Keeping them apart is the whole design: one box, many
# customers, and a customer's purchase must not move anybody else's limits.
class AccountPlanTest < ActiveSupport::TestCase
  HOSTED = LicenseToken.new(
    status: :valid,
    claims: {"sub" => "voodu-hosted", "exp" => 365.days.from_now.to_i, "tier" => "unlimited"}
  )

  # The fixture keypair the rest of the licence tests use. Signing with the real
  # key would tie the suite to a file that is gitignored — CI has no such file,
  # and rightly so.
  FIXTURES = Rails.root.join("test/fixtures/files")
  KEY = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_private_key.pem").read)
  PUBLIC = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_public_key.pem").read)

  setup do
    owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", email_verified: true)
    Account.provision!(owner: owner, account_name: "Acme", org_name: "Prod")
    @account = owner.owned_accounts.first
  end

  # Account#activate_plan! verifies against LicenseToken.public_key, so the
  # fixture key has to BE that key for the duration.
  def with_test_key
    LicenseToken.stub(:public_key, PUBLIC) { yield }
  end

  def plan_token(plan: "pro", account: @account, days: 365)
    JWT.encode({
      "sub" => account.short_id, "iat" => Time.current.to_i,
      "exp" => days.days.from_now.to_i, "tier" => "unlimited", "plan" => plan, "ent" => {}
    }, KEY, "RS256")
  end

  # An installation licence: signed by us, valid, and about the BOX. It names a
  # tier and no plan, which is exactly the token somebody pastes into the plan
  # form by mistake — the two forms are one screen apart.
  def installation_token(tier: "enterprise", account: @account)
    JWT.encode({
      "sub" => account.short_id, "iat" => Time.current.to_i,
      "exp" => 365.days.from_now.to_i, "tier" => tier, "ent" => {}
    }, KEY, "RS256")
  end

  # ── A licence that names no plan is not a plan licence ─────────────────
  #
  # It used to be accepted. Everything about it verified — signature, expiry,
  # subject — and LicenseToken#plan then fell back to "free" for the absent
  # claim, so the row was written, the screen said "Plan activated — Free.",
  # and the customer got nothing. The failure had no symptom to search for:
  # a green toast and an unchanged plan.

  test "an installation licence pasted into the plan form is refused" do
    with_test_key do
      status, detail = @account.activate_plan!(installation_token)

      assert_equal :not_a_plan, status
      assert_equal "enterprise", detail, "the tier is what tells them which licence they pasted"
    end
  end

  test "a refused installation licence is not stored" do
    with_test_key do
      @account.activate_plan!(installation_token)

      assert_nil @account.reload.plan_license_token
      assert_equal "free", @account.plan
    end
  end

  # The refusal comes BEFORE the expiry check on purpose: renewing an
  # installation licence would not make it a plan licence, so "it expired" would
  # send somebody to buy the wrong thing again.
  test "an expired installation licence is refused for what it is, not for its date" do
    with_test_key do
      expired = JWT.encode({
        "sub" => @account.short_id, "iat" => 400.days.ago.to_i,
        "exp" => 35.days.ago.to_i, "tier" => "enterprise", "ent" => {}
      }, KEY, "RS256")

      assert_equal :not_a_plan, @account.activate_plan!(expired).first
    end
  end

  # A plan claim the build does not recognise is refused rather than read as
  # free — the opposite of how an unknown TIER is treated, and deliberately:
  # falling back would quietly downgrade somebody who paid.
  test "an unrecognised plan is refused rather than silently downgraded" do
    with_test_key do
      assert_equal :not_a_plan, @account.activate_plan!(plan_token(plan: "platinum")).first
    end
  end

  # ── Whitespace anywhere in the token ───────────────────────────────────
  #
  # A token copied out of a wrapped terminal arrives with a newline in the
  # MIDDLE, which `.strip` does not touch. ruby-jwt still verifies it today and
  # warns that it will stop, so a licence stored that way works now and dies on
  # a gem bump — the installation dropping to free with nobody having touched it.

  test "a token pasted with a newline in the middle still activates" do
    with_test_key do
      token = plan_token
      wrapped = token.insert(token.length / 2, "\n")

      assert_equal :ok, @account.activate_plan!(wrapped).first
      assert_equal "pro", @account.reload.plan
    end
  end

  test "what gets stored is the token that verified, not the one that was typed" do
    with_test_key do
      token = plan_token
      @account.activate_plan!(token.insert(token.length / 2, "\n  \t"))

      stored = @account.reload.plan_license_token

      assert_no_match(/\s/, stored, "stored whitespace verifies today and stops on a jwt bump")
      assert_equal token.delete("\n \t"), stored
    end
  end

  test "an account with no licence is on the free plan" do
    assert_equal "free", @account.plan
    assert_not @account.pro?
  end

  test "activating a plan licence issued for it moves it to pro" do
    status, = with_test_key { @account.activate_plan!(plan_token) }

    assert_equal :ok, status
    with_test_key { assert_equal "pro", @account.reload.plan }
  end

  # The binding. Without it a pro licence is a file that circulates by email.
  test "a licence issued for another account is refused" do
    other_owner = User.create!(email: "other@example.com", email_verified: true)
    Account.provision!(owner: other_owner, account_name: "Globex", org_name: "Prod")
    other = other_owner.owned_accounts.first

    status, subject = with_test_key { @account.activate_plan!(plan_token(account: other)) }

    assert_equal :wrong_account, status
    assert_equal other.short_id, subject
    with_test_key { assert_equal "free", @account.reload.plan }
  end

  # Checked on READ as well as on write: a row written straight to the database,
  # or one predating the check, must not grant anything either.
  test "a foreign licence already in the column grants nothing" do
    other_owner = User.create!(email: "other2@example.com", email_verified: true)
    Account.provision!(owner: other_owner, account_name: "Globex", org_name: "Prod")

    @account.update_column(:plan_license_token, plan_token(account: other_owner.owned_accounts.first))

    with_test_key { assert_equal "free", @account.reload.plan }
  end

  # Grace applies to a plan the same way it applies to the box's licence: a
  # customer whose renewal is late does not lose their orgs overnight.
  test "a plan inside its grace period is still pro" do
    @account.update_column(:plan_license_token, plan_token(days: -5))

    with_test_key { assert_equal "pro", @account.reload.plan }
  end

  test "a plan past its grace period falls back to free" do
    @account.update_column(:plan_license_token, plan_token(days: -(LicenseToken::GRACE_PERIOD.in_days + 5)))

    with_test_key { assert_equal "free", @account.reload.plan }
  end

  # A token that stopped verifying — key rotated, row corrupted — must not take
  # the page down. Free is the honest answer and the screen can say why.
  test "an unverifiable token falls back to free rather than raising" do
    @account.update_column(:plan_license_token, "not a jwt at all")

    with_test_key do
      assert_nothing_raised { @account.reload.plan }
      assert_equal "free", @account.plan
    end
  end

  # ── The isolation that makes it a SaaS ────────────────────────────

  test "one customer's purchase does not move another's limits" do
    other_owner = User.create!(email: "neighbour@example.com", email_verified: true)
    Account.provision!(owner: other_owner, account_name: "Globex", org_name: "Prod")
    neighbour = other_owner.owned_accounts.first

    with_test_key { @account.activate_plan!(plan_token) }

    with_test_key { assert Entitlements.for(@account.reload, HOSTED).room_for_another_org? }
    assert_not Entitlements.for(neighbour, HOSTED).room_for_another_org?,
      "the neighbour's allowance moved when somebody else bought a plan"
  end

  # The expensive mistake this guards: leave the count global on a hosted box
  # and the FIRST customer to create an org consumes everybody's allowance —
  # which nobody would report as a licensing bug.
  test "an org limit counts within the account, not across the installation" do
    other_owner = User.create!(email: "busy@example.com", email_verified: true)
    Account.provision!(owner: other_owner, account_name: "Busy", org_name: "One")
    busy = other_owner.owned_accounts.first
    busy.orgs.create!(name: "Two")
    busy.orgs.create!(name: "Three")

    fresh = Entitlements.for(@account, HOSTED)

    assert_equal 1, fresh.send(:scope_for, :orgs), "another account's orgs were counted"
  end

  # Self-hosted is untouched: there the box's licence governs and an account
  # plan would be a second answer to the same question.
  test "a self-hosted installation ignores account plans entirely" do
    self_hosted = LicenseToken.new(
      status: :valid, claims: {"sub" => "acme-corp", "exp" => 30.days.from_now.to_i}
    )
    with_test_key { @account.activate_plan!(plan_token) }

    entitlements = Entitlements.for(@account.reload, self_hosted)

    # `hosted?` is gone with the second counting mode. What replaced it is the
    # question that actually matters: on a self-hosted box the LICENCE decides
    # the plan, so the account's own token is never consulted.
    assert_equal "pro", entitlements.plan, "the box's Enterprise licence upgrades its one account"
    assert_nil entitlements.limit(:orgs)
    assert_equal 1, entitlements.limit(:accounts), "Enterprise is one account, not a private SaaS"
  end
end
