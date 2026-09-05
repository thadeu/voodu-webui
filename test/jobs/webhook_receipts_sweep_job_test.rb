# frozen_string_literal: true

require "test_helper"

# Retention for the delivery log.
#
# The table is designed to be swept from day one — that is what keeps
# partitioning an option rather than a rescue: nothing holds a foreign key
# pointing at a receipt, so deleting one is a delete and not a cascade.
class WebhookReceiptsSweepJobTest < ActiveJob::TestCase
  test "deliveries past the horizon are removed" do
    old = receipt(at: 100.days.ago)
    recent = receipt(at: 10.days.ago)

    WebhookReceiptsSweepJob.perform_now

    assert_not Webhook::Receipt.exists?(old.id)
    assert Webhook::Receipt.exists?(recent.id)
  end

  # A deployment OUTLIVES the comprovante that produced it. The column carries
  # no foreign key precisely so this is possible: the id dangles, the screen
  # says the delivery expired, and real deploy history is not collateral.
  test "a swept receipt does not take its deployments with it" do
    r = receipt(at: 100.days.ago)

    d = Deployment.create!(
      org: orgs(:acme), server: servers(:alpha), repo: "acme/api", sha: "abc1234",
      status: "succeeded", webhook_receipt_id: r.id
    )

    WebhookReceiptsSweepJob.perform_now

    assert Deployment.exists?(d.id), "the deployment must survive its receipt"
    assert_nil d.reload.webhook_receipt
  end

  test "it batches rather than deleting in one statement" do
    stub_const_batch(2) do
      3.times { |i| receipt(at: (100 + i).days.ago) }

      assert_equal 3, WebhookReceiptsSweepJob.perform_now
    end
  end

  test "an empty table is a no-op" do
    assert_equal 0, WebhookReceiptsSweepJob.perform_now
  end

  private

  def receipt(at:)
    Webhook::Receipt.create!(
      provider: "github", event: "push", status: "accepted",
      external_id: SecureRandom.uuid, received_at: at, payload: {}
    )
  end

  def stub_const_batch(size)
    original = WebhookReceiptsSweepJob::BATCH
    WebhookReceiptsSweepJob.send(:remove_const, :BATCH)
    WebhookReceiptsSweepJob.const_set(:BATCH, size)

    yield
  ensure
    WebhookReceiptsSweepJob.send(:remove_const, :BATCH)
    WebhookReceiptsSweepJob.const_set(:BATCH, original)
  end
end
