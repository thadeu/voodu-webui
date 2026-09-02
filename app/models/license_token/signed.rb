# frozen_string_literal: true

# LicenseToken::Signed — mints a licence. The only place that holds the private
# key and the only place that decides what a valid claim set looks like.
#
# Extracted from lib/tasks/license.rake, where two nearly identical task bodies
# each built their own claims hash. That was fine while a human at a terminal
# was the only issuer; it stops being fine the moment a payment webhook has to
# issue one too, because a rake task cannot be called from a controller and
# `abort` cannot be rescued into a 500. So: this raises, and the rake translates
# to `abort`. Nothing here writes to stdout or ends a process.
#
# It signs and it validates. It does NOT look anything up — no Account, no
# Stripe customer. The caller knows who it is issuing for; making this class ask
# would tie minting to one particular source of truth and give the webhook a
# second one to disagree with.
#
# THE PRIVATE KEY IS NEVER COMMITTED. Looked for in this order:
#
#   VOODU_LICENSE_PRIVATE_KEY_PEM   the PEM itself
#   VOODU_LICENSE_PRIVATE_KEY       a path
#   config/license/private_key.pem  the default, gitignored by pattern
#
# The default sits beside the public half so it is easy to find and hard to
# lose, which is the tradeoff being made: a key in a working tree is one
# `git add -f` from disaster, so .gitignore covers the accident and
# test/architecture/no_private_keys_test.rb covers the rest. A vault is still
# the right home for it.
#
#   LicenseToken::Signed.new(subject: "acme-corp", days: 365,
#                            tier: "enterprise").generate!
#
#   LicenseToken::Signed.new(subject: account.short_id, days: 365,
#                            plan: "pro").generate!
class LicenseToken::Signed
  ALGORITHM = "RS256"

  DEFAULT_KEY_PATH = Rails.root.join("config/license/private_key.pem")

  # Separate from ArgumentError on purpose. A blank subject is a bug in the
  # caller; a missing signing key is an operational fact about the box, and a
  # webhook wants to tell those apart — one is a 500 to fix in code, the other
  # is a deploy that never got its key.
  class MissingKey < StandardError; end

  attr_reader :subject, :days, :tier, :plan, :entitlements

  def initialize(subject:, days:, tier: nil, plan: nil, entitlements: {}, key: nil)
    @subject = subject.to_s.strip
    @days = days.to_i
    @tier = tier.presence
    @plan = plan.presence
    @entitlements = (entitlements || {}).transform_keys(&:to_s)
    @key = key
  end

  # generate! — the signed token, as a String.
  #
  # Validates first and raises rather than signing something the product will
  # later read as nothing. A licence that verifies and grants no more than
  # having none is the worst outcome here: the customer paid, the screen says
  # it activated, and nobody finds out until they ask why nothing changed.
  def generate!
    validate!

    JWT.encode(claims, signing_key, ALGORITHM)
  end

  def issued_at = @issued_at ||= Time.current

  def expires_at = issued_at + days.days

  # The claim set, exposed so a caller can log or record what it just sold.
  def claims
    payload = {
      "sub" => subject,
      "iat" => issued_at.to_i,
      "exp" => expires_at.to_i,
      "ent" => entitlements
    }

    # Top level, not inside `ent`: they name the PRODUCT, not an entitlement.
    payload["tier"] = effective_tier if effective_tier
    payload["plan"] = plan if plan

    payload
  end

  private

  # A plan only means something on the hosted service — Entitlements#plan reads
  # the account's plan when the tier is `unlimited` and ignores it otherwise. So
  # a plan licence carries that tier by construction rather than by the caller
  # remembering to pass it, which is the kind of thing a caller remembers until
  # the day it does not.
  def effective_tier = plan ? "unlimited" : tier

  def validate!
    raise ArgumentError, "subject is required" if subject.empty?
    raise ArgumentError, "days must be a positive integer (got #{days.inspect})" unless days.positive?

    if tier && !LicenseToken::TIERS.include?(tier)
      raise ArgumentError, "tier must be one of: #{LicenseToken::TIERS.join(", ")} (got #{tier.inspect})"
    end

    if plan && !LicenseToken::PLANS.include?(plan)
      raise ArgumentError, "plan must be one of: #{LicenseToken::PLANS.join(", ")} (got #{plan.inspect})"
    end

    if plan && tier && tier != "unlimited"
      raise ArgumentError, "a plan licence is hosted-only and carries tier unlimited (got #{tier.inspect})"
    end

    validate_entitlements!
  end

  # Only keys Entitlements knows are accepted. A typo that silently signs an
  # entitlement nothing reads would look granted and behave free, and the
  # customer would find out, not us.
  def validate_entitlements!
    known = Entitlements::LICENSED.keys.map(&:to_s)
    unknown = entitlements.keys - known

    return if unknown.empty?

    raise ArgumentError,
      "unknown entitlement#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")}; " \
      "known: #{known.join(", ")}"
  end

  def signing_key
    @key ||= OpenSSL::PKey::RSA.new(pem)
  rescue OpenSSL::PKey::PKeyError => e
    raise MissingKey, "private key could not be read: #{e.message}"
  end

  def pem
    inline = ENV["VOODU_LICENSE_PRIVATE_KEY_PEM"].presence
    return inline if inline

    path = ENV["VOODU_LICENSE_PRIVATE_KEY"].presence
    path ||= DEFAULT_KEY_PATH.to_s if DEFAULT_KEY_PATH.exist?

    raise MissingKey, <<~MSG.strip if path.nil?
      no signing key: put it at #{DEFAULT_KEY_PATH}, or set
      VOODU_LICENSE_PRIVATE_KEY (a path) or VOODU_LICENSE_PRIVATE_KEY_PEM (the PEM)
    MSG

    File.read(path)
  rescue Errno::ENOENT
    raise MissingKey, "private key not found at #{path}"
  end
end
