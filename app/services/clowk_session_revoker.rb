# frozen_string_literal: true

# ClowkSessionRevoker — end someone's Clowk sessions when their access here ends.
#
# Removing a membership already takes effect on the next request: the access
# scope is read from the database every time, so the person is refused the
# moment they click anything. What it does NOT do is end the session at Clowk —
# their token stays valid, and if they hold access to some OTHER org here they
# keep browsing on a session that was minted before you removed them.
#
# So this is defence in depth, and it is deliberately BEST EFFORT. Clowk being
# unreachable must never block an admin from removing someone: the removal is
# the control, this is the tidy-up. A failure here is logged and swallowed.
#
# Needs CLOWK_SECRET_KEY — the management API authenticates with it. Without
# one this is a no-op, which is the honest behaviour: we cannot ask Clowk to do
# anything, and pretending otherwise would hide that from the operator.
class ClowkSessionRevoker
  # What the gem's retries can still surface, plus connection-refused, which
  # retries never cover.
  NETWORK_ERRORS = [SystemCallError, Timeout::Error, IOError, SocketError, EOFError].freeze

  def self.revoke_for(user)
    new(user).revoke!
  end

  def initialize(user)
    @user = user
  end

  def revoke!
    return :not_configured if Clowk.config.secret_key.blank?
    return :no_identity unless @user&.verified_email?

    sessions = find_sessions
    sessions.each { |id| client.sessions.revoke(id) }

    Rails.logger.info("[auth] revoked #{sessions.size} clowk session(s) for #{@user.email}")

    :ok
  rescue *NETWORK_ERRORS, Clowk::Error => e
    # The local removal already happened and is what actually denies access.
    Rails.logger.warn("[auth] could not revoke clowk sessions for #{@user.email}: #{e.class}")

    :unavailable
  end

  private

  def client
    @client ||= Clowk::SDK::Client.new(secret_key: Clowk.config.secret_key)
  end

  # The search is by address, which is the only handle we hold: the session ids
  # live in the tokens of the person being removed, and an admin's request has
  # no access to those.
  #
  # Reads body_parsed, not the Response itself: Clowk::Http::Response#[] is a
  # `fetch` over its OWN envelope (status/body/headers), so indexing it for a
  # payload key raises KeyError rather than returning nil.
  def find_sessions
    response = client.sessions.search(email: @user.email)
    return [] unless response.respond_to?(:success?) && response.success?

    rows(response.body_parsed).filter_map { |session| session_id_of(session) }
  end

  def rows(parsed)
    return Array(parsed[:sessions] || parsed["sessions"]) if parsed.is_a?(Hash)

    Array(parsed)
  end

  def session_id_of(session)
    return session if session.is_a?(String)
    return nil unless session.is_a?(Hash)

    session[:id] || session["id"] || session[:session_id] || session["session_id"]
  end
end
