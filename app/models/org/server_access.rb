# frozen_string_literal: true

class Org
  # Org::ServerAccess — one server a `member` may reach inside one org.
  #
  # Read through `org.servers.where(id: …)`, never through the association
  # alone: arriving via the membership FEELS scoped but is not, and this row is
  # the thing a scoping bug would forge. `org_id` plus the validation below stop
  # the row existing; the double-scoped read makes it inert if one ever does.
  class ServerAccess < ApplicationRecord
    self.table_name = "org_server_accesses"

    include HasUuidV7

    belongs_to :membership, class_name: "Org::Membership", inverse_of: :server_accesses
    belongs_to :server
    belongs_to :org

    validates :server_id, uniqueness: {scope: :membership_id}
    validate :one_org_only

    private

    # Membership, server and grant must name the SAME org. Without this, a
    # grant pairing acme's membership with globex's server would hand acme's
    # member a live PAT for globex's controller.
    def one_org_only
      return if membership.nil? || server.nil?
      return if membership.org_id == org_id && server.org_id == org_id

      errors.add(:base, "membership and server must belong to the same org")
    end
  end
end
