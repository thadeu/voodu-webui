# frozen_string_literal: true

# Setting — operator-global key/value preferences.
#
# Persisted in SQLite (single row per key). Scope is GLOBAL — Voodu
# is a single-operator console, so prefs live anchored to the
# install, not the active server. If multi-operator ever becomes a
# thing, this table gets a `user_id` column and the helpers learn
# `Setting.get(:key, user_id:)`.
#
# Usage:
#   Setting.get(:key)                # → "value" | nil
#   Setting.set(:key, "value")       # → upserts
#   Setting[:key]                    # alias for get
#
# NOTE: timezone moved to Org#timezone (a per-org display preference), so this
# table currently has NO keys. It stays as generic k/v infra for the next
# global pref (refresh cadence, theme, …) — add a KEY_* constant when one lands.
class Setting < ApplicationRecord
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
