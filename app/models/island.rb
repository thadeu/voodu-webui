# frozen_string_literal: true

# Island represents one voodu controller the WebUI talks to.
#
# Each Island carries:
#
#   - `name`     — operator-supplied label (sidebar display).
#   - `endpoint` — full URL of the controller's PAT plane,
#                  e.g. `http://203.0.113.10:8687`.
#   - `pat`      — the Personal Access Token used in
#                  `Authorization: Bearer <pat>`. Stored encrypted at
#                  rest via ActiveRecord Encryption.
#
# Static helpers (`host`, `pods_count`, `status`) feed the sidebar
# row without going to the network — `pods_count` is a cheap derived
# field cached in the future; for M3 it returns 0 (M4 caches live).
class Island < ApplicationRecord
  # Default voodu observability-plane port. The operator usually only
  # types the IP; we splice this in if no explicit port is present.
  DEFAULT_PORT = 8687

  # ActiveRecord Encryption — Rails encrypts the column at write,
  # decrypts on read. Operator never has to think about it.
  encrypts :pat_ciphertext

  before_validation :normalize_endpoint

  validates :name, presence: true, uniqueness: true, length: { maximum: 64 }
  validates :endpoint, presence: true, format: {
    with: %r{\Ahttps?://[^/]+:\d+}, message: "could not be normalised to scheme://host:port"
  }
  validates :pat_ciphertext, presence: true

  # Convenience accessor — read/write as `island.pat` even though
  # the column is named pat_ciphertext (the name tells anyone reading
  # the schema "this is encrypted, don't grep for the plaintext").
  alias_attribute :pat, :pat_ciphertext

  # Extracts the host:port portion of the endpoint for sidebar display.
  # `http://203.0.113.10:8687` → `203.0.113.10:8687`.
  def host
    URI.parse(endpoint).then { |u| [u.host, u.port].compact.join(":") }
  rescue URI::InvalidURIError
    endpoint
  end

  # M3: stubbed at 0. M4 caches the latest pod count after each
  # /pods fetch so the sidebar shows live counts without spamming
  # the controller on every page render.
  def pods_count
    0
  end

  # M3: stubbed online. M4 caches the latest reachability after each
  # successful /stats fetch — failures flip this to :offline.
  def status
    :online
  end

  private

  # normalize_endpoint — turn operator-friendly input into a fully-
  # qualified URL the HTTP client can consume.
  #
  # Accepted inputs (all normalise to `http://1.2.3.4:8687`):
  #
  #   1.2.3.4
  #   1.2.3.4:8687
  #   http://1.2.3.4
  #   http://1.2.3.4:8687
  #
  # Rules:
  #   - Missing scheme → prepend "http://" (operators don't think in
  #     schemes for an IP-addressable controller).
  #   - Missing explicit port → append ":#{DEFAULT_PORT}" right after
  #     the host. URI's "default scheme port" (80/443) does NOT count
  #     as explicit — we want the WebUI default of 8687 to win.
  #   - Custom port (e.g. operator firewalls the plane to a non-default
  #     port) → respected verbatim.
  def normalize_endpoint
    return if endpoint.blank?

    raw = endpoint.strip

    # 1. Ensure scheme.
    raw = "http://#{raw}" unless raw.match?(%r{\Ahttps?://})

    # 2. Ensure explicit port. Regex matches scheme + host (no path,
    # no query, no fragment, no `:` already). Inserts `:8687` right
    # before the path/end. We don't run unless no explicit :digits
    # appears in the authority component.
    has_port = raw.match?(%r{\Ahttps?://[^/?#]+:\d+})

    unless has_port
      raw = raw.sub(%r{\A(https?://[^/:?#]+)}, "\\1:#{DEFAULT_PORT}")
    end

    self.endpoint = raw
  rescue StandardError
    # Anything weird — leave the original value in place so the
    # format validator surfaces a clear error to the operator.
  end
end
