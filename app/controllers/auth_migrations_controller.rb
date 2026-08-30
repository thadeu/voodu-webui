# frozen_string_literal: true

# Confirming the handover of an anonymous installation's workspace.
#
# Reachable only by the address named when sign-in was turned on, and only after
# that person has signed in for real. Everything before this point is
# reversible: turning on Clowk stores credentials and touches no data, so a
# wrong publishable key costs a restart with CLOWK_ENABLED=0 and nothing else.
class AuthMigrationsController < ApplicationController
  skip_before_action :require_server!

  before_action :require_claimable_migration!

  def show
    operator = User.find_by(email: User::LOCAL_OPERATOR_EMAIL)

    render Views::AuthMigrations::Show.new(
      orgs: operator&.active_orgs&.count.to_i,
      servers: operator&.active_orgs&.sum { |org| org.servers.count }.to_i,
      owner_email: Current.user.email
    )
  end

  def create
    @config.migrate_to!(Current.user)

    redirect_to root_path(org_id: nil, server_key: nil),
      notice: "The workspace is yours. Sign-in is now required for everyone."
  end

  private

  # Only the named address, and only while the migration is outstanding. Without
  # the address check, anyone who managed to sign in could claim an entire
  # installation on their first request.
  def require_claimable_migration!
    @config = SsoConfiguration.current

    return if @config&.claimable_by?(Current.user)

    redirect_to root_path(org_id: nil, server_key: nil)
  end
end
