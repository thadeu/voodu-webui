# frozen_string_literal: true

# Give dashboards an opaque UUID for URLs (/metrics?dashboard=<uuid>,
# /metrics/dashboards/<uuid>) instead of the sequential integer id —
# non-guessable + doesn't leak how many dashboards exist.
class AddUuidToMetricDashboards < ActiveRecord::Migration[8.1]
  def up
    add_column :metric_dashboards, :uuid, :string

    MetricDashboard.reset_column_information
    MetricDashboard.where(uuid: nil).find_each do |d|
      d.update_columns(uuid: SecureRandom.uuid)
    end

    change_column_null :metric_dashboards, :uuid, false
    add_index :metric_dashboards, :uuid, unique: true
  end

  def down
    remove_column :metric_dashboards, :uuid
  end
end
