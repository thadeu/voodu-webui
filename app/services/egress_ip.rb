# frozen_string_literal: true

# EgressIp — the public address THIS dashboard reaches servers from. It exists
# for one sentence: "allow port 8687 from <ip>" in the firewall hint an operator
# sees when a freshly added server does not answer. Without the number the
# hint is homework; with it, it is a copy-paste.
#
# Resolution order:
#   1. APP_EGRESS_IP — set it when the box sits behind a NAT / egress gateway
#      whose address a lookup from inside would not report (or to skip the
#      lookup entirely on an air-gapped install).
#   2. A lookup against a reflector, cached for an hour. The address rarely
#      changes and the hint is rendered on a hot path (the overview).
#   3. nil — the hint still renders, without the number.
#
# The lookup is best-effort with a short timeout: a slow reflector must never
# hold a page render hostage.
class EgressIp
  REFLECTOR = "https://checkip.amazonaws.com"
  CACHE_KEY = "egress_ip/v1"
  TTL = 1.hour
  TIMEOUT = 3

  def self.current
    configured = ENV["APP_EGRESS_IP"].presence
    return configured if configured

    Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { lookup }
  end

  def self.lookup
    response = Faraday.new(url: REFLECTOR) { |f|
      f.options.timeout = TIMEOUT
      f.options.open_timeout = TIMEOUT
    }.get

    return nil unless response.success?

    ip = response.body.to_s.strip
    IPAddr.new(ip).to_s
  rescue Faraday::Error, ArgumentError
    nil
  end
  private_class_method :lookup
end
