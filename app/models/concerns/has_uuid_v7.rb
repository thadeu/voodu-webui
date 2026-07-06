# frozen_string_literal: true

# HasUuidV7 — a string primary key filled with a time-ordered UUIDv7 on
# create. Applied to the org-layer tables (Org now; Server in M1) so ids
# are globally unique + non-guessable AND sort by creation time (v7 embeds
# a millisecond timestamp) — no central sequence to coordinate when this
# grows into multi-node SaaS.
#
# The table must be created with a string primary key and no default
# (`create_table :x, id: :string`); we supply the value app-side because
# SQLite has no native uuid type / generator function. `id ||=` keeps
# explicitly-set ids (fixtures, imports) intact.
module HasUuidV7
  extend ActiveSupport::Concern

  included do
    before_create :assign_uuid_v7
  end

  private

  def assign_uuid_v7
    self.id ||= SecureRandom.uuid_v7
  end
end
