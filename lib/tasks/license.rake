# frozen_string_literal: true

# Issuing Enterprise licences.
#
# There is no licensing service and there should not be one until the customer
# count justifies operating it. A signed token needs a private key, a script and
# a record of who bought — this is the script. Validation stays offline in the
# product (see License), so nothing here ever has to be reachable.
#
# THE PRIVATE KEY NEVER LIVES IN THIS REPOSITORY. Point one of these at it:
#
#   VOODU_LICENSE_PRIVATE_KEY=/secure/path/voodu-license-private-key.pem
#   VOODU_LICENSE_PRIVATE_KEY_PEM="$(cat …)"
#
# Usage:
#   rake 'license:issue[acme-corp,365]'
#   rake 'license:issue[acme-corp,365,retention_days=180 orgs=5]'
#   rake 'license:inspect[eyJhbGciOi…]'
namespace :license do
  desc "Issue a signed licence: license:issue[customer,days,'k=v k=v']"
  task :issue, [:customer, :days, :overrides] => :environment do |_task, args|
    customer = args[:customer].to_s.strip
    days = args[:days].to_i

    abort "customer is required — rake 'license:issue[acme-corp,365]'" if customer.empty?
    abort "days must be a positive integer" unless days.positive?

    key = LicenseIssuing.private_key
    now = Time.current
    claims = {
      "sub" => customer,
      "iat" => now.to_i,
      "exp" => (now + days.days).to_i,
      "ent" => LicenseIssuing.parse_overrides(args[:overrides])
    }

    token = JWT.encode(claims, key, "RS256")

    warn "issued for #{customer}, expires #{Time.zone.at(claims["exp"]).to_date} " \
         "(#{days} days), entitlements: #{claims["ent"].inspect}"
    warn "record the sale — nothing here keeps a ledger."
    # stdout carries the token alone, so `rake … > acme.jwt` is usable.
    puts token
  end

  desc "Inspect a licence the way the app would: license:inspect[token]"
  task :inspect, [:token] => :environment do |_task, args|
    license = License.resolve(args[:token].to_s.strip)

    puts "status:      #{license.status}"
    puts "summary:     #{license.summary}"
    puts "customer:    #{license.customer.inspect}"
    puts "expires:     #{license.expires_at&.iso8601.inspect}"
    puts "granted:     #{license.granted.inspect}"
    puts "effective:   #{Entitlements.new(license).table.inspect}"
  end
end

# Kept out of the task bodies so the parsing has somewhere to be read and
# corrected. Not autoloaded: lib/tasks is excluded (config/application.rb).
module LicenseIssuing
  NUMERIC = /\A-?\d+\z/

  def self.private_key
    pem = ENV["VOODU_LICENSE_PRIVATE_KEY_PEM"].presence
    path = ENV["VOODU_LICENSE_PRIVATE_KEY"].presence

    pem ||= File.read(path) if path
    abort "set VOODU_LICENSE_PRIVATE_KEY (path) or VOODU_LICENSE_PRIVATE_KEY_PEM" if pem.nil?

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
