# frozen_string_literal: true

require "test_helper"

# The webhook: where a push becomes a deployment, and where every way it must
# NOT is pinned.
#
# This is the only endpoint in the app an anonymous caller can post to and have
# something happen. Two things stand between the internet and a customer's
# server — the HMAC, and the fact that the lookup starts from an installation
# id rather than from anything the caller chose. Both are tested by trying to
# get past them.
class Integrations::GithubWebhooksControllerTest < ActionDispatch::IntegrationTest
  SECRET = "webhook-s3cret"
  INSTALLATION = "9001"
  REPO = "acme/api"

  setup do
    @previous = ENV.to_hash.slice("GITHUB_APP_ID", "GITHUB_WEBHOOK_SECRET")

    # Both, not just the secret: GithubSettings lets the ENVIRONMENT decide
    # only when GITHUB_APP_ID is set, and reads the database otherwise. A test
    # that exported the secret alone would be configuring the source that is
    # being ignored.
    ENV["GITHUB_APP_ID"] = "12345"
    ENV["GITHUB_WEBHOOK_SECRET"] = SECRET

    @org = orgs(:acme)
    @server = servers(:alpha)

    @integration = Integration::Record.create!(
      org: @org, name: "GitHub", provider: "github",
      external_id: INSTALLATION, status: "active"
    )
    @integration.add_repo!(repo: REPO, server_id: @server.id, trigger_id: "trg1")
  end

  teardown do
    ENV.delete("GITHUB_APP_ID")
    ENV.delete("GITHUB_WEBHOOK_SECRET")
    @previous.each { |key, value| ENV[key] = value }
  end

  # ── the signature ──────────────────────────────────────────────────────

  test "a push with a valid signature becomes one queued deployment" do
    assert_difference -> { Deployment.count }, 1 do
      deliver(push_payload)
    end

    assert_response :success

    deployment = Deployment.last

    assert_equal @server.id, deployment.server_id
    assert_equal @org.id, deployment.org_id
    assert_equal REPO, deployment.repo
    assert_equal "trg1", deployment.trigger_id
    assert_equal "main", deployment.branch
    assert_equal "abc123def456", deployment.sha
    assert_equal "queued", deployment.status
    assert_equal "Ship it", deployment.commit_message
  end

  test "a push signed with the wrong secret is refused and writes nothing" do
    assert_no_difference -> { Deployment.count } do
      deliver(push_payload, secret: "not-the-secret")
    end

    assert_response :unauthorized
  end

  test "a push with no signature at all is refused" do
    assert_no_difference -> { Deployment.count } do
      post github_integration_webhook_path,
        params: JSON.generate(push_payload),
        headers: {"CONTENT_TYPE" => "application/json", "X-GitHub-Event" => "push"}
    end

    assert_response :unauthorized
  end

  # Fails CLOSED. An installation that never configured a secret must reject
  # deliveries, not accept them unchecked — the second is an endpoint anybody
  # can post deploys to.
  test "a push is refused when the installation has no webhook secret" do
    ENV.delete("GITHUB_WEBHOOK_SECRET")

    assert_no_difference -> { Deployment.count } do
      deliver(push_payload, secret: SECRET)
    end

    assert_response :unauthorized
  end

  # The signature covers the exact bytes GitHub sent. Verifying a re-serialised
  # hash instead would accept a body edited after it was signed.
  test "a body altered after signing is refused" do
    body = JSON.generate(push_payload)
    signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)
    tampered = body.sub("abc123def456", "000000000000")

    assert_no_difference -> { Deployment.count } do
      post github_integration_webhook_path, params: tampered, headers: {
        "CONTENT_TYPE" => "application/json",
        "X-GitHub-Event" => "push",
        "X-Hub-Signature-256" => signature
      }
    end

    assert_response :unauthorized
  end

  # ── the dedupe ─────────────────────────────────────────────────────────

  # THE DEDUPE MOVED UP a level. It used to live on `deployments.delivery_id`,
  # which only protected deliveries that produced a deployment; on the receipt
  # it covers every delivery, including the ones we refuse. The second attempt
  # now stops before any work is considered.
  test "the same delivery twice queues once" do
    assert_difference -> { Deployment.count }, 1 do
      2.times { deliver(push_payload, delivery: "d-1") }
    end

    assert_response :success
    assert JSON.parse(response.body)["duplicate"], "the retry should be recognised"

    # And one receipt, not two.
    assert_equal 1, Webhook::Receipt.where(external_id: "d-1").count
  end

  # Two pushes are two deploys even when everything else matches — a retry is a
  # repeated DELIVERY, not a repeated commit.
  test "two deliveries of the same commit queue twice" do
    assert_difference -> { Deployment.count }, 2 do
      deliver(push_payload, delivery: "d-1")
      deliver(push_payload, delivery: "d-2")
    end
  end

  # ── what does not deploy ───────────────────────────────────────────────

  test "a repository no server listed queues nothing" do
    assert_no_difference -> { Deployment.count } do
      deliver(push_payload(repo: "acme/unlisted"))
    end

    assert_response :success
  end

  # The tenant boundary, tried from the outside: the payload names a repository
  # that IS listed, under an installation that is not ours.
  test "a push from an installation we do not know queues nothing" do
    assert_no_difference -> { Deployment.count } do
      deliver(push_payload(installation: "7777"))
    end

    assert_response :success
  end

  test "a revoked integration queues nothing" do
    @integration.revoke!

    assert_no_difference -> { Deployment.count } do
      deliver(push_payload)
    end
  end

  test "a branch delete queues nothing" do
    assert_no_difference -> { Deployment.count } do
      deliver(push_payload(sha: "0" * 40).merge("deleted" => true))
    end

    assert_response :success
  end

  # The trigger file decides whether a tag fires (`on.push.tags`), and that
  # decision is the box's. The webhook only has to let the ref through.
  test "a tag push queues a deployment carrying the tag ref" do
    assert_difference -> { Deployment.count }, 1 do
      deliver(push_payload(ref: "refs/tags/v1.0.0"))
    end

    assert_response :success

    deployment = Deployment.order(:id).last
    assert_equal "refs/tags/v1.0.0", deployment.ref
    assert_equal "v1.0.0", deployment.branch
    assert deployment.tag?
  end

  test "a ref that is neither branch nor tag queues nothing" do
    assert_no_difference -> { Deployment.count } do
      deliver(push_payload(ref: "refs/notes/commits"))
    end

    assert_response :success
  end

  # ── fan-out ────────────────────────────────────────────────────────────

  # One repository, a staging box and a production one. Both fire: that is the
  # same delivery landing twice on purpose, which is why the dedupe index is
  # scoped to the server rather than global.
  test "a repository listed on two servers queues one deployment per server" do
    @integration.add_repo!(repo: REPO, server_id: servers(:beta).id, trigger_id: "trg2")

    assert_difference -> { Deployment.count }, 2 do
      deliver(push_payload, delivery: "d-fan")
    end

    assert_equal [servers(:alpha).id, servers(:beta).id].sort,
      Deployment.pluck(:server_id).sort
  end

  # ── other events ───────────────────────────────────────────────────────

  test "a ping is answered" do
    deliver({"zen" => "Keep it logically awesome."}, event: "ping")

    assert_response :success
  end

  test "an unhandled event is accepted rather than retried forever" do
    deliver({}, event: "check_run")

    assert_response :success
  end

  # Revoked, not deleted: the deployment history points at this row, and
  # deleting it would take the record of what it deployed.
  test "uninstalling the app revokes the integration and keeps it" do
    deliver({"action" => "deleted", "installation" => {"id" => INSTALLATION}},
      event: "installation")

    assert_response :success
    assert_equal "revoked", @integration.reload.status
  end

  test "an unverified installation event revokes nothing" do
    deliver({"action" => "deleted", "installation" => {"id" => INSTALLATION}},
      event: "installation", secret: "wrong")

    assert_response :unauthorized
    assert_equal "active", @integration.reload.status
  end

  private

  def push_payload(repo: REPO, installation: INSTALLATION, ref: "refs/heads/main", sha: "abc123def456")
    {
      "ref" => ref,
      "after" => sha,
      "repository" => {"full_name" => repo},
      "installation" => {"id" => installation},
      "pusher" => {"name" => "operator"},
      "head_commit" => {"message" => "Ship it\n\nwith details", "author" => {"name" => "Operator"}}
    }
  end

  def deliver(payload, event: "push", secret: SECRET, delivery: SecureRandom.uuid)
    body = JSON.generate(payload)

    post github_integration_webhook_path, params: body, headers: {
      "CONTENT_TYPE" => "application/json",
      "X-GitHub-Event" => event,
      "X-GitHub-Delivery" => delivery,
      "X-Hub-Signature-256" => "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    }
  end
end
