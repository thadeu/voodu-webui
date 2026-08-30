# frozen_string_literal: true

# Resolves the Enterprise licence once, into config.x.license, so every reader
# agrees — the entitlement table, the settings screen, and the tests that
# exercise both.
#
# Inside `to_prepare` rather than at the top level because LicenseToken is an
# autoloaded model: referencing it while initializers run is exactly what Rails
# refuses to allow. This also means development re-resolves on reload, which is
# what you want while fiddling with a token.
#
# Verification is offline and cannot fail loudly — see LicenseToken. The worst
# possible token produces a :invalid licence and the free tier, never a boot
# failure, because a licence that can stop the app from starting is a licence
# that can take a customer's monitoring down during an incident.

# Said once at boot, where an operator setting the container up will see it. A
# lapsed or unverifiable licence is worth a warning: it means capabilities the
# operator is paying for silently stopped applying.
Rails.application.config.after_initialize do
  license = LicenseToken.current
  next if license.status == :none

  message = "[license] #{license.summary}"

  case license.status
  when :valid then Rails.logger.info(message)
  else Rails.logger.warn(message)
  end
end

# Postgres without an entitlement, said once where the operator will see it.
# Not a refusal — the control plane is already in that database and declining to
# read it would lock the operator out of their own data rather than enforce
# anything. What the product owes here is visibility; the terms do the rest.
Rails.application.config.after_initialize do
  adapter = ActiveRecord::Base.connection_db_config.adapter
  next unless Entitlements.current.unlicensed_adapter?(adapter)

  Rails.logger.warn(
    "[license] the control plane is in Postgres, which is an Enterprise capability. " \
    "Nothing has been restricted. See Settings for the current plan."
  )
rescue ActiveRecord::ActiveRecordError => e
  Rails.logger.debug { "[license] could not inspect the primary adapter: #{e.class}" }
end
