# frozen_string_literal: true

# LicenseToken — what this deployment bought, read from a signed token.
#
# Named for the token rather than the licence because Ops::License is the stored
# activation. Inside the Ops namespace a bare `License` resolves to that model,
# so a verifier called `License` would be reachable only as `::License` — the
# kind of shadowing that is invisible until something quietly resolves to the
# wrong class.
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
class LicenseToken
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

  attr_reader :claims, :reason

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

  # current — the licence in force, resolved fresh.
  #
  # Two places can hold one: VOODU_LICENSE in the environment, and an activation
  # saved in the database from Settings. NEWEST ISSUED WINS, from either side,
  # which is the only rule that serves all three real situations — an operator
  # who only ever sets the env var, one who renews by pasting into Settings, and
  # one who keeps compose in git and updates the env on renewal. Neither side
  # silently undoes the other.
  #
  # Resolved per call rather than cached: measured at 0.07ms to verify and 0.3ms
  # to read the row, which is not worth a cache whose invalidation would have to
  # cross Puma workers.
  #
  # config.x.license, when it holds a License, overrides everything. That is the
  # test seam; production never sets it. Checked with is_a? rather than presence
  # because config.x returns a truthy empty OrderedOptions for anything unset.
  def self.current
    configured = Rails.application.config.x.license
    return configured if configured.is_a?(LicenseToken)

    candidates = [resolve(token_from_env, source: :env), from_database].reject { |l| l.status == :none }
    verified = candidates.select(&:verified?)

    return verified.max_by { |l| l.issued_at || Time.zone.at(0) } if verified.any?

    # Nothing verified. Report a failure if there was one to report, so Settings
    # can explain itself; otherwise this really is the free tier.
    candidates.first || new(status: :none)
  end

  def self.from_database
    key = Ops::License.current
    return new(status: :none) if key.nil?

    resolve(key.token, source: :database)
  rescue ActiveRecord::ActiveRecordError => e
    # A licence must never be the reason a page 500s — not even when the table
    # is missing because a migration has not run yet.
    Rails.logger.error("[license] could not read the stored licence: #{e.class}")
    new(status: :none)
  end

  def self.resolve(token = token_from_env, key: public_key, now: Time.current, source: :env)
    return new(status: :none) if token.blank?
    return new(status: :invalid, reason: "no public key", source: source) if key.nil?

    # verify_expiration is off so an expired licence still yields its claims —
    # the settings screen has to be able to say WHOSE licence expired and when,
    # and grace needs the date to measure against.
    claims, = JWT.decode(token, key, true, algorithm: "RS256", verify_expiration: false)

    return new(status: :invalid, reason: "no exp", source: source) if claims["exp"].blank?

    new(status: :signed, claims: claims, token: token, source: source)
  rescue JWT::DecodeError, OpenSSL::PKey::PKeyError => e
    new(status: :invalid, reason: e.class.name.demodulize, source: source)
  end

  # :signed marks "the signature held" and nothing about time. Where the licence
  # sits in its lifetime is decided in #status, on every read.
  def initialize(status:, claims: {}, reason: nil, token: nil, source: :none)
    @verified = status
    @claims = claims || {}
    @reason = reason
    @token = token
    @source = source
  end

  attr_reader :token

  # Where this licence came from: :env, :database or :none. Reported so the
  # screen can say it; it does NOT decide precedence.
  #
  # Precedence is by issue date — see .current. An operator whose env-supplied
  # licence expires buys a newer one and pastes it into the form, and the newer
  # one wins. Making the environment win outright would have made that flow
  # impossible: the form would be gone at exactly the moment it was needed.
  attr_reader :source

  def env_supplied? = source == :env

  # Derived on READ, never stored.
  #
  # This used to be computed once and frozen into the object, which meant a
  # container running past its expiry date kept reporting :valid forever — the
  # licence never actually expired in a long-lived process, only in one that
  # happened to restart. Asking the clock at the moment of the question is the
  # whole fix, and it needs no scheduled job to prop it up.
  def status
    return @verified unless @verified == :signed

    expires = expires_at
    now = Time.current

    return :valid if now <= expires + LEEWAY
    return :grace if now <= expires + GRACE_PERIOD

    :lapsed
  end

  # Whether this licence currently grants anything. Grace counts — that is the
  # point of grace.
  def entitled? = ENTITLED.include?(status)

  def present? = status != :none

  # Whether the signature held, regardless of where the licence sits in time.
  # An expired licence still verified — that is what lets Settings show whose
  # it was and when it lapsed, instead of a shrug.
  def verified? = @verified == :signed

  def issued_at
    iat = claims["iat"]
    iat.present? ? Time.zone.at(iat.to_i) : nil
  end

  def customer = claims["sub"].presence

  # Which product this licence is. Three exist:
  #
  #   free        no licence at all — the self-hosted default
  #   enterprise  a licence somebody bought for their own installation
  #   unlimited   the hosted service's own licence, on the box we run
  #
  # A claim rather than something inferred from the entitlements: "unlimited"
  # and "a very generous enterprise licence" would otherwise be the same thing
  # to read, and the screen has to name what somebody is running.
  #
  # Unknown values fall back to enterprise. A licence signed by us with a tier
  # this build has not heard of is still a licence, and refusing to honour it
  # would turn a forward-compatible claim into an outage.
  TIERS = %w[enterprise unlimited].freeze

  def tier
    return "free" unless entitled?

    claimed = claims["tier"].to_s
    TIERS.include?(claimed) ? claimed : "enterprise"
  end

  def unlimited? = tier == "unlimited"

  # Which plan a HOSTED customer bought. Meaningless on a self-hosted
  # installation, where the licence on the box already says what they have.
  #
  # Free is the default and the answer for anyone who never bought anything, so
  # an absent claim is not an error — most accounts will never carry a licence
  # at all and resolve to free without one.
  PLANS = %w[free pro].freeze
  DEFAULT_PLAN = "free"

  def plan
    claimed = claims["plan"].to_s

    PLANS.include?(claimed) ? claimed : DEFAULT_PLAN
  end

  # Who this licence was sold to, as an account's short_id.
  #
  # A plan licence that named nobody would be a file that circulates by email:
  # one customer's pro licence pasted into another customer's account. The
  # activation refuses a subject that is not the account activating it, and
  # this is the field it checks.
  def subject_account = claims["sub"].to_s.presence

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
