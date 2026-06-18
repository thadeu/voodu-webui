class AddRegionAndInfraToIslands < ActiveRecord::Migration[8.1]
  # Free-text metadata the operator fills in at island registration.
  # The controller has no notion of region or infra — these labels
  # exist purely so the WebUI's topbar can surface "fra1 · hetzner"
  # next to the island name. No uniqueness, no validation, no enum:
  # operators name their regions whatever they want ("fra1",
  # "us-east-1", "office", "homelab") and the infra column is just
  # a hint ("hetzner", "aws", "bare-metal", "k8s").
  #
  # Nullable because every existing island predates this column —
  # the form lets you leave them blank and the topbar collapses the
  # chip when both are absent.
  def change
    add_column :islands, :region, :string
    add_column :islands, :infra, :string
  end
end
