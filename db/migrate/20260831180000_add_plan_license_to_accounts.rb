# frozen_string_literal: true

# Per-account plan licences, for the hosted service.
#
# The installation licence answers "what is this box" and lives in ops_licenses,
# one row for the whole deployment. That is right for self-hosted, where the box
# and the customer are the same party, and wrong for a hosted service where one
# box serves many — a customer pasting their licence into the installation's
# screen would replace everyone's.
#
# So a plan lives on the account it was sold to. Stored as the signed token
# rather than as a parsed plan name, for the same reason the installation
# licence is: the token IS the proof, and a plain `plan` column would be a claim
# anybody with database access could grant themselves.
class AddPlanLicenseToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :plan_license_token, :text
    add_column :accounts, :plan_activated_at, :datetime
  end
end
