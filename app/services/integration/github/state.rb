# frozen_string_literal: true

# Integration::Github::State — the signed value that ties a GitHub callback
# back to the person and the server who started it.
#
# WHY IT EXISTS. The callback arrives at our door carrying `installation_id` in
# the query string, in the browser of whoever is logged in. Without this, a
# signed-in attacker could paste SOMEBODY ELSE'S installation id and bind that
# installation to their own org — and then read every repository the victim had
# authorized, using a token we would mint for them ourselves.
#
# So the flow starts here: we sign who is going, and refuse a return that does
# not carry it back.
#
# Signed and NOT stored. A row would need cleaning up, would need a lookup on a
# path that has no session yet, and would answer the same question — the
# signature already proves we minted it, and the expiry already bounds it.
class Integration::Github::State
  # Long enough to authorize an App on GitHub, including reading the permission
  # screen and picking repositories out of a list. Short enough that a link
  # left in a browser history is not a working credential tomorrow.
  TTL = 30.minutes

  PURPOSE = "integration.github.connect"

  Payload = Struct.new(:org_id, :server_id, :user_id)

  def self.generate(org:, server:, user:)
    verifier.generate(
      {"org_id" => org.id, "server_id" => server.id, "user_id" => user.id},
      purpose: PURPOSE,
      expires_in: TTL
    )
  end

  # verify — the payload, or nil for anything we did not mint, that expired, or
  # that was minted for something else.
  #
  # Nil rather than an exception: every failure here means the same thing to
  # the caller (start over), and a tampered value is not exceptional — it is
  # the case this exists for.
  def self.verify(raw)
    data = verifier.verified(raw.to_s, purpose: PURPOSE)

    return nil if data.blank?

    Payload.new(
      org_id: data["org_id"],
      server_id: data["server_id"],
      user_id: data["user_id"]
    )
  end

  # `purpose` is not decoration: without it a value signed for one thing is a
  # valid value for every other thing this app signs with the same verifier.
  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
end
