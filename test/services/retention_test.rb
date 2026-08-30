# frozen_string_literal: true

require "test_helper"

# Two windows that must never collapse into one.
#
# The last two tests are the reason this class exists at all: a licence narrows
# what can be SEEN and must never narrow what is KEPT. Get that backwards and a
# lapsed licence deletes a paying customer's history during the week their
# renewal is on someone's desk.
class RetentionTest < ActiveSupport::TestCase
  setup do
    @previous = ENV["VOODU_RETENTION_DAYS"]
    @license = Rails.application.config.x.license
  end

  teardown do
    ENV["VOODU_RETENTION_DAYS"] = @previous
    # The licence is process-wide state; a test that swaps it and walks away
    # poisons whatever runs next.
    Rails.application.config.x.license = @license
  end

  def entitled(days)
    Entitlements.new(LicenseToken.new(
      status: :valid, claims: {"sub" => "acme", "exp" => 1.year.from_now.to_i,
                               "ent" => {"retention_days" => days}}
    ))
  end

  def free = Entitlements.new(LicenseToken.new(status: :none))

  test "keep_days defaults to what the sweeper always kept" do
    ENV.delete("VOODU_RETENTION_DAYS")

    assert_equal LogTail::FilePath::RETENTION_DAYS, Retention.keep_days
  end

  test "the operator sets how long bytes live" do
    ENV["VOODU_RETENTION_DAYS"] = "90"

    assert_equal 90, Retention.keep_days
  end

  test "a nonsense keep window falls back rather than deleting everything" do
    ["", "  ", "zero", "-5", "0"].each do |junk|
      ENV["VOODU_RETENTION_DAYS"] = junk

      assert_operator Retention.keep_days, :>=, 1, "#{junk.inspect} must not produce a sweep of everything"
    end
  end

  # You cannot serve what was never kept, and you may not serve past what was
  # bought. The smaller wins, whichever side it comes from.
  test "serving is the smaller of kept and licensed" do
    ENV["VOODU_RETENTION_DAYS"] = "90"

    assert_equal 30, Retention.serve_days(entitled(30)), "the licence is the binding side here"

    ENV["VOODU_RETENTION_DAYS"] = "7"

    assert_equal 7, Retention.serve_days(entitled(90)), "the disk is the binding side here"
  end

  test "the free tier serves only what a default install keeps" do
    ENV.delete("VOODU_RETENTION_DAYS")

    assert_equal LogTail::FilePath::RETENTION_DAYS, Retention.serve_days(free)
  end

  # ── The rule, asserted directly ────────────────────────────────────────

  test "the keep window is identical under every licence state" do
    ENV["VOODU_RETENTION_DAYS"] = "90"
    baseline = Retention.keep_days

    [:none, :valid, :grace, :lapsed, :invalid].each do |status|
      Rails.application.config.x.license = LicenseToken.new(status: status, claims: {"exp" => 1.day.ago.to_i})

      assert_equal baseline, Retention.keep_days,
        "a #{status} licence changed how long bytes are kept — that deletes customer data"
    end
  end

  test "a lapsed licence narrows what is served without touching what is kept" do
    ENV["VOODU_RETENTION_DAYS"] = "90"
    lapsed = Entitlements.new(LicenseToken.new(status: :lapsed, claims: {"exp" => 90.days.ago.to_i}))

    assert_equal 90, Retention.keep_days, "the bytes stay"
    assert_equal 3, Retention.serve_days(lapsed), "the view narrows to the free tier"
  end
end
