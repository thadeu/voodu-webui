# frozen_string_literal: true

# Setting — operator-global key/value preferences.
#
# Persisted in SQLite (single row per key). Scope is GLOBAL — Voodu
# is a single-operator console, so prefs live anchored to the
# install, not the active island. If multi-operator ever becomes a
# thing, this table gets a `user_id` column and the helpers learn
# `Setting.get(:timezone, user_id:)`.
#
# Usage:
#   Setting.get(:timezone)                # → "America/Sao_Paulo" | nil
#   Setting.set(:timezone, "UTC")         # → upserts
#   Setting[:timezone]                    # alias for get
#
# Known keys live as constants below — typoed key names go silently
# (Setting.get("timezon") returns nil instead of raising), so the
# constants are the safety net for callers.
class Setting < ApplicationRecord
  KEY_TIMEZONE = "timezone"

  validates :key, presence: true, uniqueness: true

  # Pull the value for a key, or nil if unset. String returned
  # verbatim — no automatic type coercion, the caller decides.
  def self.get(key)
    where(key: key.to_s).pick(:value)
  end

  # Upsert the value. Pass `nil` or `""` to clear back to default.
  # Returns the persisted record so caller can chain.
  def self.set(key, value)
    record = find_or_initialize_by(key: key.to_s)
    record.value = value.to_s
    record.save!
    record
  end

  # Read-side alias matching Hash semantics.
  def self.[](key)
    get(key)
  end
end
