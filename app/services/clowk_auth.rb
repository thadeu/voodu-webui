# frozen_string_literal: true

# ClowkAuth — is operator sign-in switched on for this process?
#
# The answer is computed once at boot by config/initializers/clowk.rb (the
# switch plus both keys) and parked on config.x. This reads it back, so the
# routes file and ClowkGuard can never disagree about whether auth is live.
class ClowkAuth
  def self.enabled?
    Rails.application.config.x.clowk_auth_enabled == true
  end
end
