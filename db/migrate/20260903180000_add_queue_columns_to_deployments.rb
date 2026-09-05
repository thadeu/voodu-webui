# frozen_string_literal: true

# What the queue needs beyond what the webhook wrote.
#
# `remote_job_id` closes the loop with the box: the deploy endpoint answers with
# a job id, and without storing it a deployment here cannot be matched to the
# activity line there. Nullable — a deployment that never reached the box has
# no job to name, and that is a state rather than a gap.
#
# The two partial indexes serve the two hot questions and nothing else:
# "what is running" (asked by the sweeper on every tick and by the screen) and
# "what failed" (asked by the screen). Partial rather than full because
# succeeded rows are the overwhelming majority and indexing them would be
# paying for the answer nobody asks.
class AddQueueColumnsToDeployments < ActiveRecord::Migration[8.1]
  def change
    add_column :deployments, :remote_job_id, :string

    add_index :deployments, [:server_id, :repo, :created_at],
      name: "index_deployments_on_serialization_key"

    add_index :deployments, :started_at,
      where: "status = 'running'", name: "index_deployments_running"

    add_index :deployments, :created_at,
      where: "status = 'failed'", name: "index_deployments_failed"
  end
end
