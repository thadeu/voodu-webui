# frozen_string_literal: true

# ActiveRecord Encryption keys.
#
# Production / staging:
#   Edit `config/credentials.yml.enc` and add the three keys under
#   `active_record_encryption:` — Rails reads them automatically.
#
# Development / test:
#   We use hardcoded keys here so a clone-and-run loop doesn't need
#   the master.key. These are NOT secret — anyone who can read the
#   repo can read the encrypted pat_ciphertext columns, but in dev
#   the SQLite file lives on the same machine anyway. Production
#   credentials override these via the standard Rails mechanism.
if Rails.env.development? || Rails.env.test?
  Rails.application.config.active_record.encryption.tap do |enc|
    enc.primary_key            = "dev-only-primary-key-not-secret-1eVBVAu"
    enc.deterministic_key      = "dev-only-deterministic-key-not-secre"
    enc.key_derivation_salt    = "dev-only-key-derivation-salt-not-secret"
  end
end
