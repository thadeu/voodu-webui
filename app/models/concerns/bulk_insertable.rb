# frozen_string_literal: true

# BulkInsertable — the warehouse write path. Pollers hand us an Array of
# column-shaped Hashes; insert them in one round-trip (insert_all skips
# validations + callbacks, which is what we want for append-only rows).
# Returns the number written; a blank batch is a no-op.
module BulkInsertable
  extend ActiveSupport::Concern

  class_methods do
    def bulk_insert(rows)
      return 0 if rows.blank?

      insert_all(rows)
      rows.size
    end
  end
end
