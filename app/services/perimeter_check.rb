# frozen_string_literal: true

require "ipaddr"

# PerimeterCheck — "is this request arriving from outside a perimeter?"
#
# Only meaningful in anonymous mode (CLOWK_ENABLED off), where the app asks for
# no credentials because something in front of it already did: Twingate, a VPN,
# Cloudflare Access. That arrangement is correct and it is what the self-hosted
# shape is built around. What it cannot survive is the port being published
# straight to the internet — whoever arrives is the owner, and an owner reveals
# PATs. A PAT is the whole controller: deploy, exec, logs. So the failure mode
# is not a leaked chart, it is somebody else's infrastructure.
#
# Nothing here BLOCKS. Refusing public addresses would break the legitimate
# deployment where the perimeter forwards a real client IP, and a dashboard that
# locks the operator out of their own box is worse than one that warns. This
# only decides whether to say something, loudly and permanently, in the UI.
#
# Twingate and most VPNs put the app behind a connector on the private network,
# so remote_ip lands in RFC1918 and nothing is said. Cloudflare Access forwards
# the real public client IP, which would look identical to an exposed port from
# here — that deployment silences this with VOODU_TRUSTED_PERIMETER=1 rather
# than having us guess from headers anyone can send.
class PerimeterCheck
  def self.trusted_perimeter?
    ENV["VOODU_TRUSTED_PERIMETER"].to_s.strip == "1"
  end

  # `remote_ip`, not REMOTE_ADDR: Rails has already walked X-Forwarded-For past
  # the proxies it trusts, which is the address that actually describes who is
  # calling.
  def self.exposed?(remote_ip)
    return false if trusted_perimeter?

    ip = IPAddr.new(remote_ip.to_s)

    !(ip.loopback? || ip.private? || ip.link_local?)
  rescue IPAddr::InvalidAddressError
    # An address we cannot parse is one we cannot vouch for. Same posture as
    # SsrfGuard: "we could not tell" never means "all good".
    true
  end
end
