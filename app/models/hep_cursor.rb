# frozen_string_literal: true

# HepCursor — the Hep3 poller's resume point for one (server, reader
# instance). Persists the opaque "<file>:<offset>" cursor the voodu-hep3
# /export endpoint returns in X-Hep-Cursor, so each poll pulls strictly
# newer lines (no re-read, no duplicates).
class HepCursor < HepRecord
  # cursor_for — the last persisted cursor, or "" when this instance has
  # never been polled (cold start → /export from the beginning).
  def self.cursor_for(server_id, scope, name)
    find_by(server_id: server_id, scope: scope, name: name)&.cursor.to_s
  end

  # advance — persist the next cursor for this instance (upsert on the
  # unique (server, scope, name) index).
  def self.advance(server_id, scope, name, cursor)
    rec = find_or_initialize_by(server_id: server_id, scope: scope, name: name)
    rec.cursor = cursor.to_s
    rec.save!
    rec
  end
end
