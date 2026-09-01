# frozen_string_literal: true

# Issuing Enterprise licences.
#
# There is no licensing service and there should not be one until the customer
# count justifies operating it. A signed token needs a private key, a script and
# a record of who bought — this is the script. Validation stays offline in the
# product (see License), so nothing here ever has to be reachable.
#
# THE PRIVATE KEY IS NEVER COMMITTED. It is looked for in this order:
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
# Usage:
#   bundle exec rake 'license:inspect[eyJhbGciOi…]'
#
#   bundle exec rake 'license:issue[acme-corp,365]'
#   bundle exec rake 'license:issue[acme-corp,365,retention_days=180 orgs=5]'
#   bundle exec rake 'license:issue[voodu-hosted,365,tier=unlimited]'
#
#   Self-hosted free -> enterprise
#   bundle exec rake 'license:issue[local-dev,30,tier=enterprise]'
#
namespace :license do
  desc "Issue a signed licence: license:issue[customer,days,'k=v k=v']"
  task :issue, [:customer, :days, :overrides] => :environment do |_task, args|
    customer = args[:customer].to_s.strip
    days = args[:days].to_i

    abort "customer is required — rake 'license:issue[acme-corp,365]'" if customer.empty?
    abort "days must be a positive integer" unless days.positive?

    key = LicenseIssuing.private_key
    now = Time.current

    # `tier` travels in the same free-form argument as the entitlement
    # overrides, and is pulled out BEFORE they are parsed — parse_overrides
    # rejects keys it does not know, and rightly so: a typo in an entitlement
    # name should fail loudly rather than sign a licence granting nothing.
    tier, override_string = LicenseIssuing.split_tier(args[:overrides])
    overrides = LicenseIssuing.parse_overrides(override_string)

    if tier.present? && !LicenseToken::TIERS.include?(tier)
      abort "tier must be one of: #{LicenseToken::TIERS.join(", ")} (got #{tier.inspect})"
    end
    claims = {
      "sub" => customer,
      "iat" => now.to_i,
      "exp" => (now + days.days).to_i,
      "ent" => overrides
    }

    # Top level, not inside `ent`: it names the PRODUCT, not an entitlement.
    claims["tier"] = tier if tier.present?

    token = JWT.encode(claims, key, "RS256")

    warn "issued for #{customer}, tier #{claims["tier"] || "enterprise"}, expires " \
         "#{Time.zone.at(claims["exp"]).to_date} (#{days} days), " \
         "entitlements: #{claims["ent"].inspect}"
    warn "record the sale — nothing here keeps a ledger."
    # stdout carries the token alone, so `rake … > acme.jwt` is usable.
    puts token
  end

  # Plan licences, for customers of the hosted service.
  #
  # Bound to ONE account by short_id. Without that binding a pro licence is a
  # file that circulates: one customer's, pasted into another customer's
  # account. Account#activate_plan! refuses a subject that is not the account
  # activating it, and this is what puts the subject there.
  desc "Issue a plan licence for one hosted account: license:issue_plan[short_id,days,plan]"
  task :issue_plan, [:account, :days, :plan, :overrides] => :environment do |_task, args|
    short_id = args[:account].to_s.strip
    days = args[:days].to_i
    plan = args[:plan].to_s.strip.presence || LicenseToken::DEFAULT_PLAN

    abort "account short_id is required — rake 'license:issue_plan[Pz9IUrm2,365,pro]'" if short_id.empty?
    abort "days must be a positive integer" unless days.positive?
    abort "plan must be one of: #{LicenseToken::PLANS.join(", ")}" unless LicenseToken::PLANS.include?(plan)

    # Looked up, not just accepted. A typo in a short_id would otherwise
    # produce a signed licence for an account that does not exist, which the
    # customer discovers when they paste it and we discover never.
    account = Account.find_by(short_id: short_id)
    abort "no account with short_id #{short_id.inspect}" if account.nil?

    key = LicenseIssuing.private_key
    now = Time.current

    token = JWT.encode({
      "sub" => short_id,
      "iat" => now.to_i,
      "exp" => (now + days.days).to_i,
      "tier" => "unlimited",
      "plan" => plan,
      "ent" => LicenseIssuing.parse_overrides(args[:overrides])
    }, key, "RS256")

    warn "issued #{plan} for #{account.name} (#{short_id}), expires " \
         "#{Time.zone.at(now.to_i + days.days).to_date} (#{days} days)"
    warn "record the sale — nothing here keeps a ledger."
    puts token
  end

  desc "Inspect a licence the way the app would: license:inspect[token]"
  task :inspect, [:token] => :environment do |_task, args|
    license = LicenseToken.resolve(args[:token].to_s.strip)

    puts "status:      #{license.status}"
    puts "summary:     #{license.summary}"
    puts "customer:    #{license.customer.inspect}"
    puts "expires:     #{license.expires_at&.iso8601.inspect}"
    puts "tier:        #{license.tier}"
    puts "granted:     #{license.granted.inspect}"
    puts "effective:   #{Entitlements.new(license).table.inspect}"
  end
end

# Kept out of the task bodies so the parsing has somewhere to be read and
# corrected. Not autoloaded: lib/tasks is excluded (config/application.rb).
module LicenseIssuing
  NUMERIC = /\A-?\d+\z/

  DEFAULT_PATH = Rails.root.join("config/license/private_key.pem")

  def self.private_key
    pem = ENV["VOODU_LICENSE_PRIVATE_KEY_PEM"].presence
    path = ENV["VOODU_LICENSE_PRIVATE_KEY"].presence
    path ||= DEFAULT_PATH.to_s if pem.nil? && DEFAULT_PATH.exist?

    pem ||= File.read(path) if path

    if pem.nil?
      abort "no signing key: put it at #{DEFAULT_PATH}, or set " \
            "VOODU_LICENSE_PRIVATE_KEY (path) or VOODU_LICENSE_PRIVATE_KEY_PEM"
    end

    OpenSSL::PKey::RSA.new(pem)
  rescue Errno::ENOENT
    abort "private key not found at #{path}"
  rescue OpenSSL::PKey::PKeyError => e
    abort "private key could not be read: #{e.message}"
  end

  # "retention_days=180 orgs=5" → {"retention_days" => 180, "orgs" => 5}
  #
  # Only keys Entitlements knows are accepted: a typo that silently signs an
  # entitlement nothing reads would look granted and behave free, and the
  # customer would find out, not us.
  # Separates `tier=x` from the entitlement overrides sharing the same argument.
  # Returns [tier_or_nil, the_rest].
  def self.split_tier(raw)
    parts = raw.to_s.split
    tier = parts.find { |p| p.start_with?("tier=") }

    [tier&.split("=", 2)&.last, (parts - [tier]).join(" ")]
  end

  def self.parse_overrides(raw)
    known = Entitlements::LICENSED.keys.map(&:to_s)

    raw.to_s.split.to_h { |pair| pair.split("=", 2) }.filter_map { |key, value|
      abort "unknown entitlement #{key.inspect}; known: #{known.join(", ")}" unless known.include?(key)

      [key, cast(value)]
    }.to_h
  end

  def self.cast(value)
    return true if value == "true"
    return false if value == "false"
    return nil if value == "null"
    return value.to_i if NUMERIC.match?(value)

    value
  end
end
