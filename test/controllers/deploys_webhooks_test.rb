# frozen_string_literal: true

require "test_helper"

# The Webhooks tab: every delivery that arrived, and what became of it.
#
# THE GAP THIS CLOSES. Before it, only a delivery that produced work left a
# trace — so "GitHub never called", "GitHub called and we refused it" and
# "nothing matched" were the same silence from inside the product. They send an
# operator to three different places, and one of them is not even our system.
class DeploysWebhooksTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"

  setup do
    @licensed = Rails.application.config.x.license
    saas!

    @org = orgs(:acme)
    @server = servers(:alpha)

    # The list is fenced per server: an `accepted` delivery shows where its
    # repository deploys. The suite's default repository deploys here.
    listed_here!("acme/api")
  end

  teardown { Rails.application.config.x.license = @licensed }

  # ── the outcomes that used to vanish ───────────────────────────────────

  test "a refused signature is recorded and visible" do
    receipt = receipt_for("refused_signature")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_match(/signature did not verify/i, response.body)
    assert_includes response.body, deploys_webhook_path(org_id: ACME, server_key: @server.key, id: receipt.id)
  end

  # The payload of a refused delivery is NOT stored: it did not verify, so it
  # is unauthenticated bytes we have no reason to keep.
  test "a refused delivery keeps no payload" do
    r = Webhook::Receipt.record(
      provider: "github", event: "push", status: "refused_signature",
      external_id: "d-refused", payload: {}
    ).first

    assert_empty r.payload_hash
  end

  test "a delivery no server listed is recorded with the repository" do
    receipt_for("no_target", reference: "acme/unlisted")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_match(/no server listed it/i, response.body)
    assert_includes response.body, "acme/unlisted"
  end

  # The status word says what happened; the detail says what to do about it.
  test "the detail explains the outcome in the operator's terms" do
    receipt = receipt_for("no_target", reference: "acme/unlisted")

    get deploys_webhook_path(org_id: ACME, server_key: @server.key, id: receipt.id)

    assert_response :success
    assert_match(/connect it to a server/i, response.body)
  end

  test "a refused delivery's detail names the secret as the cause" do
    receipt = receipt_for("refused_signature")

    get deploys_webhook_path(org_id: ACME, server_key: @server.key, id: receipt.id)

    assert_match(/secret configured on the provider/i, response.body)
  end

  # ── the loop ───────────────────────────────────────────────────────────

  # One delivery can fan out to several deployments — a repository listed on
  # two servers — which is exactly why the link lives on the child and not as a
  # polymorphic `subject` here.
  test "a delivery lists everything it produced" do
    receipt = receipt_for("accepted", reference: "acme/api")

    a = deployment(receipt: receipt, sha: "aaa111aaa111", server: servers(:alpha))
    b = deployment(receipt: receipt, sha: "bbb222bbb222", server: servers(:beta))

    get deploys_webhook_path(org_id: ACME, server_key: @server.key, id: receipt.id)

    assert_response :success
    assert_match(/Produced · 2/, response.body)
    assert_includes response.body, a.short_sha
    assert_includes response.body, b.short_sha
  end

  # ── scoping ────────────────────────────────────────────────────────────

  # The installation is one per account; the tab is one server's. A push that
  # deployed to another box, or that matched nothing for a repository this box
  # never listed, is not this server's webhook history.
  test "a delivery that produced work elsewhere is not listed on this server" do
    receipt = receipt_for("accepted", reference: "acme/elsewhere")
    deployment(receipt: receipt, sha: "ccc333ccc333", server: servers(:beta), repo: "acme/elsewhere")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_not_includes response.body, deploys_webhook_path(org_id: ACME, server_key: @server.key, id: receipt.id)

    get deploys_webhooks_path(org_id: ACME, server_key: servers(:beta).key)

    assert_includes response.body, deploys_webhook_path(org_id: ACME, server_key: servers(:beta).key, id: receipt.id)
  end

  test "a nothing-to-do delivery shows only where its repository is listed" do
    receipt = receipt_for("skipped", reference: "acme/other")
    listed_here!("acme/other", server: servers(:beta))

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_not_includes response.body, deploys_webhook_path(org_id: ACME, server_key: @server.key, id: receipt.id)

    get deploys_webhooks_path(org_id: ACME, server_key: servers(:beta).key)

    assert_includes response.body, deploys_webhook_path(org_id: ACME, server_key: servers(:beta).key, id: receipt.id)
  end

  test "trouble outcomes stay visible on every server" do
    receipt = receipt_for("no_target", reference: "acme/orphan")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_includes response.body, deploys_webhook_path(org_id: ACME, server_key: @server.key, id: receipt.id)
  end

  # A delivery that resolved an org is fenced to it. One that did NOT — a
  # refused signature, a repository nobody listed — belongs to the
  # installation, and hiding it would hide exactly what somebody came to find.
  test "another org's delivery is not listed" do
    mine = receipt_for("accepted", reference: "acme/api", org_id: @org.id)
    theirs = receipt_for("accepted", reference: "other/app", org_id: orgs(:voidco).id)

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_includes response.body, mine.reference
    assert_not_includes response.body, theirs.reference
  end

  test "an unattributed delivery is visible to the installation" do
    orphan = receipt_for("refused_signature", org_id: nil)

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_includes response.body,
      deploys_webhook_path(org_id: ACME, server_key: @server.key, id: orphan.id)
  end

  # ── the filters ────────────────────────────────────────────────────────

  test "filtering by outcome narrows the list" do
    bad = receipt_for("refused_signature", reference: "acme/one")
    ok = receipt_for("accepted", reference: "acme/two")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key, status: "refused_signature")

    # Scoped to the TABLE. The repository dropdown lists every reference that
    # has ever arrived — by design, so a filter can be undone — so asserting
    # against the whole page catches the filter's own options.
    assert_includes table, bad.reference
    assert_not_includes table, ok.reference
  end

  test "the search matches the delivery id" do
    listed_here!("acme/one", "acme/two")
    hit = receipt_for("accepted", reference: "acme/one", external_id: "abc-123-find-me")
    receipt_for("accepted", reference: "acme/two", external_id: "zzz-999")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key, q: "find-me")

    assert_includes table, hit.reference
    assert_not_includes table, "acme/two"
  end

  # ── the sender ─────────────────────────────────────────────────────────

  # In a list of deploys the person is the fastest thing to recognize and the
  # least useful to read — you scan for "one of mine", and a face answers that
  # where a login costs a word of column width per row.
  test "the list shows who pushed, with the login on hover" do
    Webhook::Receipt.create!(
      provider: "github", event: "push", status: "accepted",
      external_id: SecureRandom.uuid, reference: "acme/api", org_id: @org.id,
      received_at: Time.current, payload: {},
      details: {
        "sender" => "thadeu",
        "sender_avatar" => "https://avatars.githubusercontent.com/u/77889?v=4",
        "sender_url" => "https://github.com/thadeu"
      }
    )

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_includes response.body, "avatars.githubusercontent.com/u/77889"
    assert_includes response.body, %(role="tooltip")
    assert_includes response.body, "group-hover/sender:opacity-100"
  end

  # An empty cell left the column ragged — half the rows with a circle and half
  # without, reading as rows that failed to load rather than rows nobody
  # signed. The silhouette says UNKNOWN rather than inventing a person: a ping,
  # or a delivery we refused, genuinely has no sender.
  test "a delivery with no sender draws an unknown silhouette" do
    receipt_for("accepted")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_includes response.body, %(aria-label="Unknown sender")
    assert_match(/role="tooltip"[^>]*>Unknown sender/, response.body)
  end

  # Same diameter as a real avatar, so the column lines up whoever signed.
  test "the silhouette matches the avatar's size" do
    receipt_for("accepted")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    px = Components::UI::Avatar::SIZES.fetch(:xs)

    assert_includes response.body, %(style="width: #{px}px; height: #{px}px;")
  end

  # Sized by class and not by inline style: PhlexIcons ships `size-6`, and a
  # style attribute only wins that by specificity — a rule that holds until the
  # library changes its default.
  test "the glyph is sized the way every other icon here is" do
    receipt_for("accepted")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    glyph = response.body[/<svg class="w-3 h-3"[^>]*>/]

    assert_not_nil glyph, "the silhouette should size its glyph by class"
    assert_not_includes response.body, "size-6"
  end

  # ── the strip lines up ─────────────────────────────────────────────────

  # A cell that DISAPPEARS takes its column width with it, and every header to
  # its right stops lining up with the rows below. The Sender component draws
  # nothing when nobody pushed — correct — so the SLOT has to be drawn by the
  # row instead.
  test "the sender slot is reserved even when there is no sender" do
    receipt_for("accepted")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_slot_reserved(response.body)
  end

  # The same invariant on the OTHER table. The first version only covered
  # Webhooks, so breaking the Deployments row changed nothing it could see — it
  # passed with the bug reintroduced.
  test "the deployments table reserves the sender slot too" do
    Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: "abc1234abc",
      status: "succeeded", details: {"commit_message" => "Ship it"}
    )

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_slot_reserved(response.body)
  end

  # NESTED ANCHORS are invalid, and they do not fail quietly: the parser closes
  # the outer `<a>` at the inner one, so every cell after the avatar spills out
  # of the row. Only the rows that HAVE a sender break, which reads as a
  # styling bug and is a markup one.
  #
  # Pinned on BOTH tables, because the first version of this file only covered
  # one and the other stayed broken.
  test "a row does not nest a link inside its own link" do
    with_sender

    [deploys_webhooks_path(org_id: ACME, server_key: @server.key),
      deploys_deployments_path(org_id: ACME, server_key: @server.key)].each do |path|
      get path

      rows = response.body.scan(%r{<a href="[^"]*/deploys/\w+/\d+".*?</a>}m)

      assert_predicate rows, :any?, "expected rows at #{path}"
      rows.each do |row|
        assert_not_includes row, "<a href=\"https://github.com",
          "a row at #{path} nests an anchor, which breaks its layout"
      end
    end
  end

  # `<span><div>` is invalid for the same reason, and was the first half of
  # this bug.
  test "the sender slot is a div, because it contains one" do
    Webhook::Receipt.create!(
      provider: "github", event: "push", status: "accepted",
      external_id: SecureRandom.uuid, reference: "acme/api", org_id: @org.id,
      received_at: Time.current, payload: {},
      details: {"sender" => "thadeu", "sender_avatar" => "https://example.test/a.png"}
    )

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_not_includes response.body, %(<span class="hidden vmd:block w-5 shrink-0">)
    assert_includes response.body, %(<div class="hidden vmd:block w-5 shrink-0">)
  end

  # Every control in the strip at ONE height. A dropdown a few pixels shorter
  # than the chips beside it does not read as a different control, it reads as
  # a mistake.
  test "the filter controls share a height" do
    receipt_for("accepted")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    strip = response.body.scan(%r{<form[^>]*deploys/webhooks[^>]*>.*?</form>}m).join

    assert_predicate strip, :present?, "the filter forms should render"

    # THE THREE CONTROLS COMPARED TO EACH OTHER, not to the constant.
    #
    # Reading CONTROL_H on both sides was tautological: it moved with the
    # constant and passed while the chips stayed behind at a different value —
    # the exact bug this exists to catch. Comparing rendered elements catches
    # it whatever the value is.
    #
    # Identified positively rather than by excluding panels: the custom-range
    # popover's button and inputs are taller on purpose, they live in a panel,
    # and every attempt to exclude them by class caught something else instead.
    heights = {
      "preset chip" => strip[/class="[^"]*px-2\.5 (h-[\w\[\]]+)[^"]*"[^>]*>\s*24h/, 1],
      "dropdown trigger" => strip[/class="px-2\.5 (h-[\w\[\]]+) min-w-/, 1],
      "search box" => strip[/class="[^"]*pl-7 pr-2 (h-[\w\[\]]+)/, 1]
    }

    heights.each { |name, h| assert_not_nil h, "could not find the #{name}" }

    assert_equal 1, heights.values.uniq.size,
      "the strip's controls should share one height, saw #{heights.inspect}"
  end

  # ── the tab ────────────────────────────────────────────────────────────

  test "the rail offers all three tabs" do
    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    rail = response.body[%r{<nav[^>]*Deploys sections.*?</nav>}m]

    assert_includes rail, deploys_repositories_path(org_id: ACME, server_key: @server.key)
    assert_includes rail, deploys_deployments_path(org_id: ACME, server_key: @server.key)
    assert_includes rail, deploys_webhooks_path(org_id: ACME, server_key: @server.key)
  end

  test "a frame request answers with the frame" do
    receipt_for("accepted")

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key),
      headers: {"Turbo-Frame" => DeploysController::WEBHOOKS_FRAME}

    assert_match(/<turbo-frame[^>]*id="#{DeploysController::WEBHOOKS_FRAME}"/o, response.body)
    assert_no_match(/<aside/, response.body)
  end

  test "a plan without the deploy plane does not reach the tab" do
    Rails.application.config.x.license = LicenseToken.new(status: :none)

    get deploys_webhooks_path(org_id: ACME, server_key: @server.key)

    assert_redirected_to server_root_path(org_id: ACME, server_key: @server.key)
  end

  private

  # A receipt and a deployment that both carry a sender, so a row renders the
  # avatar on either table.
  def with_sender
    details = {
      "sender" => "thadeu", "sender_avatar" => "https://example.test/a.png",
      "sender_url" => "https://github.com/thadeu", "commit_message" => "Ship it"
    }

    Webhook::Receipt.create!(
      provider: "github", event: "push", status: "accepted",
      external_id: SecureRandom.uuid, reference: "acme/api", org_id: @org.id,
      received_at: Time.current, payload: {}, details: details
    )

    Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: "aa0c3ba000",
      status: "failed", details: details
    )
  end

  # A cell that disappears takes its column width with it, and every header to
  # its right stops lining up.
  def assert_slot_reserved(body)
    assert_includes body, %(<div class="w-5 shrink-0">), "the header should reserve the column"
    assert_includes body, %(<div class="hidden vmd:block w-5 shrink-0">),
      "the row should reserve it too, sender or not"
  end

  # The rows, without the filter bar above them — the dropdowns legitimately
  # name every value that has ever arrived.
  def table
    response.body[/Provider.*/m].to_s
  end

  # listed_here! — point repositories at the server under test, so an
  # `accepted` delivery for them belongs on this server's tab (the list is
  # fenced per server; see WebhookReceiptsData#scope_for_org).
  def listed_here!(*repos, server: @server)
    integration = Integration::Record.active.find_by(org: @org, provider: "github") ||
      Integration::Record.create!(org: @org, name: "GitHub", provider: "github", external_id: "inst-test", status: "active")

    repos.each do |repo|
      integration.add_repo!(repo: repo, server_id: server.id, trigger_id: "t-#{repo.tr("/", "-")}-#{server.id}")
    end
  end

  def receipt_for(status, reference: "acme/api", org_id: :default, external_id: nil)
    Webhook::Receipt.create!(
      provider: "github", event: "push", status: status,
      external_id: external_id || SecureRandom.uuid,
      reference: reference,
      org_id: (org_id == :default) ? @org.id : org_id,
      payload: {"ref" => "refs/heads/main"}, received_at: Time.current
    )
  end

  def deployment(receipt:, sha:, server:, repo: "acme/api")
    Deployment.create!(
      org: @org, server: server, repo: repo, sha: sha, status: "succeeded",
      webhook_receipt_id: receipt.id, details: {"commit_message" => "Ship it"}
    )
  end

  def saas!
    Rails.application.config.x.license = LicenseToken.new(
      status: :valid,
      claims: {"sub" => "acme", "tier" => "unlimited", "exp" => 90.days.from_now.to_i}
    )
  end
end
