# frozen_string_literal: true

# RenamePollerDigestsIslandIdToTenantId — flips the wire-contract column
# name to match the platform-internal "tenant" vocabulary used by the
# poller feature.
#
# Rationale:
#
#   The poller digest table is purely a receipt for the Go binary's
#   "I dropped a folder, please process it" POST. Renaming inside the
#   feature keeps the wire shape (`tenant_id` in the JSON envelope), the
#   column, the model attribute, the service kwarg, and the controller
#   param all aligned.
#
#   The older domain tables (pods / systems / log_exports) keep their
#   `island_id` columns — they predate this naming pass and a sweep
#   across them is out of scope for this change.
#
# Index rename:
#
#   ActiveRecord's `rename_column` migrates the column inside the
#   composite `[island_id, type, created_at]` index transparently but
#   keeps the legacy index NAME (`index_poller_digests_on_island_id_...`).
#   We rename it explicitly so `schema.rb` reads cleanly post-rename and
#   the index doesn't mislead anyone reading EXPLAIN output.
class RenamePollerDigestsIslandIdToTenantId < ActiveRecord::Migration[8.1]
  def change
    rename_column :poller_digests, :island_id, :tenant_id

    rename_index :poller_digests,
      "index_poller_digests_on_island_id_and_type_and_created_at",
      "index_poller_digests_on_tenant_id_and_type_and_created_at"
  end
end
