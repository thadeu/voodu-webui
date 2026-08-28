# frozen_string_literal: true

require "ipaddr"
require "resolv"

# SsrfGuard — "may this app fetch that URL?", in one place.
#
# The WebUI runs INSIDE the private network it manages: every voodu controller
# sits on an RFC1918 address, and so do the app's own /internal/poller
# endpoints. So any feature that fires an operator-supplied URL server-side is
# a request primitive aimed at that network — an outbound call the operator
# writes and the server makes, from a position the operator does not otherwise
# hold. That is the SSRF shape, and there are two such features now
# (`WebhookClient` for alert delivery, `DataTable::HttpFetch` for data-table
# panels), which is exactly one too many to keep the rule in only one of them.
#
# Returns a Result rather than raising, because the two callers need different
# failure semantics: a webhook delivery distinguishes "blocked" (discard, never
# retry) from "cannot resolve" (transient, retry), while a data-table fetch
# turns everything into an inline error message. Encoding that here would force
# one of them to translate exceptions back into its own taxonomy.
class SsrfGuard
  # :ok — go ahead
  # :blocked — refuse, permanently (bad scheme, no host, non-routable target)
  # :unresolvable — DNS said nothing; may be a transient resolver blip
  Result = Struct.new(:status, :message) do
    def ok? = status == :ok

    def unresolvable? = status == :unresolvable
  end

  OK = Result.new(:ok, nil).freeze

  # Whether to permit non-routable (loopback / private / link-local) hosts.
  # voodu-webui is a self-hosted dashboard, so in dev/test we allow them (the
  # operator legitimately points it at a local API). In production we block by
  # default as defence-in-depth — an operator running entirely on a private
  # network opts back in with VOODU_ALLOW_PRIVATE_WEBHOOKS=1.
  #
  # The env var keeps its original name: it predates this extraction and is
  # already in operators' .env files. One switch covers both callers, which is
  # also the honest model — "this deploy may reach private hosts" is a property
  # of the network, not of the feature asking.
  def self.allow_private_hosts?
    Rails.env.local? || ENV["VOODU_ALLOW_PRIVATE_WEBHOOKS"] == "1"
  end

  def self.check(url, allow_private: allow_private_hosts?)
    new(url, allow_private: allow_private).check
  end

  def initialize(url, allow_private:)
    @url = url.to_s
    @allow_private = allow_private
  end

  def check
    uri = URI.parse(@url)

    return blocked("must be an http(s) URL") unless %w[http https].include?(uri.scheme)
    return blocked("missing host") if uri.host.blank?
    return OK if @allow_private

    resolved = addresses(uri.host)
    return Result.new(:unresolvable, "cannot resolve #{uri.host}") if resolved.empty?

    non_routable = resolved.find { |ip| non_routable?(ip) }
    return blocked("host resolves to a non-routable address (#{non_routable})") if non_routable

    OK
  rescue URI::InvalidURIError
    blocked("invalid URL")
  end

  private

  def blocked(message) = Result.new(:blocked, message)

  # A bare IP literal is checked directly; a hostname is resolved (both A and
  # AAAA). An empty result is reported as unresolvable rather than allowed —
  # "we could not tell" must never mean "go ahead".
  def addresses(host)
    return [host] if ip_literal?(host)

    Resolv.getaddresses(host)
  end

  def non_routable?(ip)
    addr = IPAddr.new(ip)

    addr.loopback? || addr.private? || addr.link_local?
  rescue IPAddr::InvalidAddressError
    # An address we cannot parse is one we cannot vouch for.
    true
  end

  def ip_literal?(host)
    IPAddr.new(host)
    true
  rescue IPAddr::InvalidAddressError
    false
  end
end
