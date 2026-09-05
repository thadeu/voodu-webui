# frozen_string_literal: true

# The link from a deployment back to the delivery that caused it.
#
# ON THE CHILD, and that direction is the design. One push to a repository
# listed on two servers creates two deployments — a polymorphic `subject` on
# the receipt would hold one of them and silently drop the other, which is the
# same class of bug `for_delivery` was written to avoid.
#
# NO FOREIGN KEY CONSTRAINT, and that is also deliberate: receipts expire on a
# retention job, and a deployment must outlive the comprovante that produced
# it. The column goes null, the screen says the delivery has expired, and the
# deployment keeps its own history. A constraint here would either block the
# cleanup or cascade away real deploy history.
#
# It is also what keeps partitioning cheap if this ever needs it — a foreign
# key pointing AT a partitioned table is what makes dropping a partition hard.
class AddWebhookReceiptToDeployments < ActiveRecord::Migration[8.1]
  def change
    add_column :deployments, :webhook_receipt_id, :integer

    add_index :deployments, :webhook_receipt_id
  end
end
