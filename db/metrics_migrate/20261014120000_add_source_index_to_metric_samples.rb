# frozen_string_literal: true

# The poller's restart watermark is MAX(ts_epoch) over the sources the poller
# writes (system / pod / ingress), not over every row: the WebUI writes its own
# rows too (`log` counts, `fswapi` overview samples) stamped "now", and a
# watermark that counted them would skip controller samples the poller had not
# pulled yet. MAX per (server, source) comes straight off this index; the old
# (server_id, ts_epoch) one cannot answer it once source is in the WHERE.
class AddSourceIndexToMetricSamples < ActiveRecord::Migration[8.1]
  def change
    add_index :metric_samples, [:server_id, :source, :ts_epoch],
      name: "idx_metric_samples_source_ts"
  end
end
