# frozen_string_literal: true

# License — what this deployment bought, read from a signed token.
#
# Verified OFFLINE. The public key ships in the image (config/license/
# public_key.pem) and the private half never touches this repository, so a
# licence is checked with no network call at all. That is not an optimisation:
# the deployments that buy one are the closed-network ones, and an install that
# has to reach us to start working puts our uptime inside their incident
# budget — the same objection that keeps Clowk optional in the self-hosted
# shape.
#
# NOTHING HERE RAISES. Absent, malformed and expired are ordinary states with
# defined answers, because the alternative is a licence that can take a
# customer's dashboard down — and a monitoring tool that fails closed at 3am is
# worse than one that quietly drops to the free tier. Every failure resolves to
# a License instance whose #status says why, so the settings screen can explain
# itself instead of the operator filing a ticket.
#
# Expiry is a slope, not a cliff: GRACE_PERIOD keeps entitlements alive after
# `exp` so a renewal that lands late is an inconvenience rather than an outage.
class License
  # Read at boot into config.x.license (config/initializers/license.rb), which
  # is what the rest of the app talks to.
  PUBLIC_KEY_PATH = Rails.root.join("config/license/public_key.pem")

  # Entitlements survive this long past `exp`, with the UI escalating. Renewal
  # paperwork takes longer than anyone plans for.
  GRACE_PERIOD = 30.days

  # The customer's clock is not ours to trust to the second.
  LEEWAY = 5.minutes

  # :none    — no token supplied; the free self-hosted shape
  # :valid   — signed, and inside its window
  # :grace   — signed, past exp, still inside GRACE_PERIOD
  # :lapsed  — signed, past exp and past grace
  # :invalid — signature, algorithm or shape failed
  ENTITLED = %i[valid grace].freeze

  attr_reader :status, :claims, :reason

  def self.public_key
    @public_key ||= OpenSSL::PKey::RSA.new(PUBLIC_KEY_PATH.read)
  rescue Errno::ENOENT, OpenSSL::PKey::PKeyError => e
    # A missing or corrupt key means nobody can present a licence — which is
    # the free tier, not an outage.
    Rails.logger.error("[license] cannot read the public key: #{e.class}")
    nil
  end

  # token_from_env — VOODU_LICENSE wins; VOODU_LICENSE_FILE is for operators
  # who keep secrets as files rather than environment.
  def self.token_from_env
    inline = ENV["VOODU_LICENSE"].to_s.strip
    return inline if inline.present?

    path = ENV["VOODU_LICENSE_FILE"].to_s.strip
    return "" if path.empty?

    File.read(path).strip
  rescue SystemCallError => e
    Rails.logger.error("[license] cannot read VOODU_LICENSE_FILE: #{e.class}")
    ""
  end

  def self.resolve(token = token_from_env, key: public_key, now: Time.current)
    return new(status: :none) if token.blank?
    return new(status: :invalid, reason: "no public key") if key.nil?

    # verify_expiration is off so an expired licence still yields its claims —
    # the settings screen has to be able to say WHOSE licence expired and when,
    # and grace needs the date to measure against.
    claims, = JWT.decode(token, key, true, algorithm: "RS256", verify_expiration: false)

    new(status: status_for(claims, now), claims: claims)
  rescue JWT::DecodeError, OpenSSL::PKey::PKeyError => e
    new(status: :invalid, reason: e.class.name.demodulize)
  end

  def self.status_for(claims, now)
    exp = claims["exp"]
    return :invalid if exp.blank?

    expires = Time.zone.at(exp.to_i)
    return :valid if now <= expires + LEEWAY
    return :grace if now <= expires + GRACE_PERIOD

    :lapsed
  end
  private_class_method :status_for

  def initialize(status:, claims: {}, reason: nil)
    @status = status
    @claims = claims || {}
    @reason = reason
  end

  # Whether this licence currently grants anything. Grace counts — that is the
  # point of grace.
  def entitled? = ENTITLED.include?(status)

  def present? = status != :none

  def customer = claims["sub"].presence

  def expires_at
    exp = claims["exp"]
    exp.present? ? Time.zone.at(exp.to_i) : nil
  end

  def expired? = %i[grace lapsed].include?(status)

  def days_until_expiry
    return nil if expires_at.nil?

    ((expires_at - Time.current) / 1.day).ceil
  end

  # The raw entitlement claims. Entitlements is what interprets them; this only
  # hands over what was signed, symbolised so callers do not juggle both.
  def granted
    return {} unless entitled?

    (claims["ent"] || {}).symbolize_keys
  end

  # One line for the settings screen and the boot log.
  def summary
    case status
    when :none then "no licence — free tier"
    when :valid then "licensed to #{customer}, expires #{expires_at.to_date}"
    when :grace then "licensed to #{customer}, EXPIRED #{expires_at.to_date} — in grace"
    when :lapsed then "licence for #{customer} lapsed #{expires_at.to_date}"
    when :invalid then "licence could not be verified (#{reason})"
    end
  end
end
