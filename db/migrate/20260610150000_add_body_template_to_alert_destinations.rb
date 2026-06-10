# frozen_string_literal: true

# Generic webhooks can carry a custom JSON body template with
# {{token}} placeholders (same substitution model as clowk-voodu's
# on_probe/on_deploy webhooks). Not a secret — shown back on edit —
# so a plain text column. Blank → the default structured payload.
class AddBodyTemplateToAlertDestinations < ActiveRecord::Migration[8.1]
  def change
    add_column :alert_destinations, :body_template, :text
  end
end
