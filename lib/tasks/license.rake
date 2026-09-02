# frozen_string_literal: true

# Issuing licences from a terminal.
#
# There is no licensing service and there should not be one until the customer
# count justifies operating it. A signed token needs a private key, a script and
# a record of who bought — this is the script. Validation stays offline in the
# product (see LicenseToken), so nothing here ever has to be reachable.
#
# THE SIGNING LIVES IN LicenseToken::Signed, not here. These tasks only do what
# is genuinely about a command line: unpack one free-form string argument into
# claims, look up the account a plan is being sold to, print the result, and
# turn an exception into `abort`. A payment webhook will call the same class and
# must not inherit any of that — `abort` in a controller is a dead process, not
# a 500. The key lookup and its error messages moved there too.
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
#   Hosted account free -> pro (bound to that account by short_id)
#   bundle exec rake 'license:pro[Pz9IUrm2,365]'
#
namespace :license do
  desc "Issue a signed licence: license:issue[customer,days,'k=v k=v']"
  task :issue, [:customer, :days, :overrides] => :environment do |_task, args|
    customer = args[:customer].to_s.strip
    abort "customer is required — rake 'license:issue[acme-corp,365]'" if customer.empty?

    # `tier` travels in the same free-form argument as the entitlement
    # overrides and is pulled out BEFORE they are parsed, because
    # LicenseToken::Signed rejects entitlement keys it does not know — rightly,
    # but that would make `tier=` read as a typo.
    tier, override_string = LicenseArgs.split_tier(args[:overrides])

    signed = LicenseToken::Signed.new(
      subject: customer,
      days: args[:days],
      tier: tier,
      entitlements: LicenseArgs.parse_overrides(override_string)
    )

    token = LicenseArgs.sign(signed)

    warn "issued for #{signed.subject}, tier #{signed.claims["tier"] || "enterprise"}, expires " \
         "#{signed.expires_at.to_date} (#{signed.days} days), " \
         "entitlements: #{signed.entitlements.inspect}"
    warn "record the sale — nothing here keeps a ledger."
    # stdout carries the token alone, so `rake … > acme.jwt` is usable.
    puts token
  end

  # Pro licences, for customers of the hosted service.
  #
  # Pro is the only plan worth signing. Free is what an account IS without a
  # licence — Account#plan falls back to it whenever there is nothing entitled
  # to read — so a token claiming `plan: "free"` produces a state
  # indistinguishable from having none, and an argument that can only be filled
  # in one useful way is an argument that gets filled in wrongly.
  #
  # Bound to ONE account by short_id. Without that binding a pro licence is a
  # file that circulates: one customer's, pasted into another customer's
  # account. Account#activate_plan! refuses a subject that is not the account
  # activating it, and this is what puts the subject there.
  desc "Issue a pro licence for one hosted account: license:pro[short_id,days]"
  task :pro, [:account, :days, :overrides] => :environment do |_task, args|
    short_id = args[:account].to_s.strip
    abort "account short_id is required — rake 'license:pro[Pz9IUrm2,365]'" if short_id.empty?

    # Looked up, not just accepted. A typo in a short_id would otherwise produce
    # a signed licence for an account that does not exist, which the customer
    # discovers when they paste it and we discover never. The lookup is the
    # terminal's job: a webhook already holds the account it is charging.
    account = Account.find_by(short_id: short_id)
    abort "no account with short_id #{short_id.inspect}" if account.nil?

    signed = LicenseToken::Signed.new(
      subject: short_id,
      days: args[:days],
      plan: "pro",
      entitlements: LicenseArgs.parse_overrides(args[:overrides])
    )

    token = LicenseArgs.sign(signed)

    warn "issued pro for #{account.name} (#{short_id}), expires " \
         "#{signed.expires_at.to_date} (#{signed.days} days)"
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

# Argument handling for the tasks above — the shape of a command line, not of a
# licence. Not autoloaded: lib/tasks is excluded (config/application.rb).
module LicenseArgs
  NUMERIC = /\A-?\d+\z/

  # Turns LicenseToken::Signed's exceptions into the two things a terminal
  # wants: a message and a non-zero exit. Each task checks its own required
  # argument first, so what reaches here is a bad value rather than a missing
  # one and the class's own wording is the clearest available.
  def self.sign(signed)
    signed.generate!
  rescue ArgumentError, LicenseToken::Signed::MissingKey => e
    abort e.message
  end

  # Separates `tier=x` from the entitlement overrides sharing the same argument.
  # Returns [tier_or_nil, the_rest].
  def self.split_tier(raw)
    parts = raw.to_s.split
    tier = parts.find { |p| p.start_with?("tier=") }

    [tier&.split("=", 2)&.last, (parts - [tier]).join(" ")]
  end

  # "retention_days=180 orgs=5" → {"retention_days" => 180, "orgs" => 5}
  #
  # Only splits and casts. Whether a key is one Entitlements knows is decided by
  # LicenseToken::Signed, so a webhook passing a hash gets the same refusal.
  def self.parse_overrides(raw)
    raw.to_s.split.to_h { |pair| pair.split("=", 2) }.transform_values { |v| cast(v) }
  end

  def self.cast(value)
    return true if value == "true"
    return false if value == "false"
    return nil if value == "null"
    return value.to_i if NUMERIC.match?(value)

    value
  end
end
