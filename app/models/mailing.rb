# frozen_string_literal: true

# Mailing — whether this installation sends email at all.
#
# Only our cloud console has a 1billion key. A self-hosted install has none, so
# every email path stays off there and the screens keep working as before
# (an invitation is a link to copy, an alert destination is a webhook).
module Mailing
  def self.enabled? = ENV["ONEBILLION_API_KEY"].present?
end
