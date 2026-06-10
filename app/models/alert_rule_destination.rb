# frozen_string_literal: true

# Join between an AlertRule and the AlertDestinations it notifies.
# Absence of rows for a rule means "notify all enabled destinations"
# (see AlertRule#destinations_for).
class AlertRuleDestination < ApplicationRecord
  belongs_to :alert_rule
  belongs_to :alert_destination
end
