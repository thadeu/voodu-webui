# frozen_string_literal: true

require "test_helper"

# The Deployments TAB of the Deploys screen, and the loop it closes: from a deployment to
# the pods it created, and from a pod back to the deployment.
#
# That loop is what makes the feature belong in this product rather than in a
# GitHub Action. Everything else here is the list behaving.
class DeploysDeploymentsTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"

  setup do
    @licensed = Rails.application.config.x.license
    saas!

    @org = orgs(:acme)
    @server = servers(:alpha)
  end

  teardown { Rails.application.config.x.license = @licensed }

  # ── the loop ───────────────────────────────────────────────────────────

  test "a deployment links to the pods running what it applied" do
    deployment = succeeded(resources: [{"kind" => "deployment", "scope" => "runa", "name" => "web"}])

    pod = Pod.create!(
      server: @server, container_name: "runa-web.a1b2", kind: "deployment",
      scope: "runa", resource_name: "web", payload: "{}", synced_at: Time.current
    )

    get deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)

    assert_response :success
    assert_includes response.body, "runa/web"
    assert_includes response.body, pod_path(org_id: ACME, server_key: @server.key, name: pod.container_name)
  end

  # A resource whose containers are gone is exactly what somebody opens this
  # page to find out. Saying nothing would read as a rendering bug.
  test "a resource with no running containers says so" do
    deployment = succeeded(resources: [{"kind" => "deployment", "scope" => "runa", "name" => "gone"}])

    get deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)

    assert_response :success
    assert_match(/no containers running this/i, response.body)
  end

  test "a pod page links back to the deployment that put it there" do
    deployment = succeeded(resources: [{"kind" => "deployment", "scope" => "runa", "name" => "web"}])

    Pod.create!(
      server: @server, container_name: "runa-web.a1b2", kind: "deployment",
      scope: "runa", resource_name: "web", payload: "{}", synced_at: Time.current
    )

    get pod_path(org_id: ACME, server_key: @server.key, name: "runa-web.a1b2")

    assert_response :success
    assert_includes response.body, deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)
  end

  # Most pods on most boxes are applied by hand. A strip saying "no deployment"
  # on every one of them would be a permanent empty row on the busiest page in
  # the product.
  test "a pod nothing deployed gets no deployment strip" do
    Pod.create!(
      server: @server, container_name: "manual.c3d4", kind: "deployment",
      scope: "runa", resource_name: "manual", payload: "{}", synced_at: Time.current
    )

    get pod_path(org_id: ACME, server_key: @server.key, name: "manual.c3d4")

    assert_response :success
    assert_no_match(/deployed from/i, response.body)
  end

  # The match is on (scope, name), and the scope half has to count: two boxes
  # running `web` in `staging` and `prod` must not cross-link.
  test "a deployment of another scope does not claim this pod" do
    succeeded(resources: [{"kind" => "deployment", "scope" => "staging", "name" => "web"}])

    Pod.create!(
      server: @server, container_name: "prod-web.a1b2", kind: "deployment",
      scope: "prod", resource_name: "web", payload: "{}", synced_at: Time.current
    )

    get pod_path(org_id: ACME, server_key: @server.key, name: "prod-web.a1b2")

    assert_response :success
    assert_no_match(/deployed from/i, response.body)
  end

  # ── the list ───────────────────────────────────────────────────────────

  test "the list shows this server's deployments, newest first" do
    older = succeeded(sha: "aaa1111aaa")
    travel 1.second
    newer = succeeded(sha: "bbb2222bbb")

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_operator response.body.index(newer.short_sha), :<, response.body.index(older.short_sha)
  end

  test "the list is scoped to the server in the URL" do
    elsewhere = Deployment.create!(
      org: @org, server: servers(:beta), repo: "acme/other",
      sha: "ccc3333ccc", status: "succeeded"
    )

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_not_includes response.body, elsewhere.short_sha
  end

  # Same answer for a deployment that never existed and one on another server:
  # the query is scoped, so there is nothing to tell apart and nothing to leak
  # by trying.
  test "a deployment of another server is not reachable by id" do
    elsewhere = Deployment.create!(
      org: @org, server: servers(:beta), repo: "acme/other",
      sha: "ccc3333ccc", status: "succeeded"
    )

    get deploys_deployment_path(org_id: ACME, server_key: @server.key, id: elsewhere.id)

    assert_redirected_to deploys_deployments_path(org_id: ACME, server_key: @server.key)
  end

  test "filtering by status narrows the list" do
    ok = succeeded(sha: "aaa1111aaa")
    bad = Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: "bbb2222bbb",
      status: "failed", error: "the build did not compile"
    )

    get deploys_deployments_path(org_id: ACME, server_key: @server.key, status: "failed")

    assert_response :success
    assert_includes response.body, bad.short_sha
    assert_not_includes response.body, ok.short_sha
  end

  # Nothing has ever deployed here is a different state from a filter matching
  # nothing, and the next step is different too.
  test "a server with no deployments points at the connected repositories" do
    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_match(/nothing has deployed to this server yet/i, response.body)
    assert_includes response.body, deploys_repositories_path(org_id: ACME, server_key: @server.key)
  end

  test "a filter matching nothing does not read as an empty history" do
    succeeded

    get deploys_deployments_path(org_id: ACME, server_key: @server.key, status: "failed")

    assert_response :success
    assert_match(/no deployment matches those filters/i, response.body)
    assert_no_match(/nothing has deployed to this server yet/i, response.body)
  end

  # ── one screen, two tabs ───────────────────────────────────────────────

  test "the bare deploys path lands on the repositories tab" do
    get "/#{ACME}/#{@server.key}/deploys"

    assert_redirected_to deploys_repositories_path(org_id: ACME, server_key: @server.key)
  end

  # Both tabs reachable from either, which is the point of folding them into
  # one screen: "did my push land" starts at a repository and ends here.
  test "each tab offers the other" do
    connect_github!

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_includes response.body, deploys_repositories_path(org_id: ACME, server_key: @server.key)

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_includes response.body, deploys_deployments_path(org_id: ACME, server_key: @server.key)
  end

  # The main sidebar carries ONE entry now. Two was a navigation problem for
  # one question.
  test "the main sidebar offers deploys once, not twice" do
    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    nav = response.body[%r{<aside.*?</aside>}m].to_s

    assert_includes nav, deploys_repositories_path(org_id: ACME, server_key: @server.key)
    assert_not_includes nav, deploys_deployments_path(org_id: ACME, server_key: @server.key)
  end

  # A Turbo-Frame request must answer WITH a frame of the same id. A bare
  # fragment has none for Turbo to find, so the panel renders "Content missing"
  # and the real body flashes past on the way there — which is exactly what it
  # did.
  test "a frame request answers with the frame, not a bare fragment" do
    succeeded

    get deploys_deployments_path(org_id: ACME, server_key: @server.key),
      headers: {"Turbo-Frame" => DeploysController::FRAME}

    assert_response :success
    assert_match(/<turbo-frame[^>]*id="#{DeploysController::FRAME}"/o, response.body)

    # And only the frame — no layout, no sidebar.
    assert_no_match(/<aside/, response.body)
  end

  # The rows link to a deployment's DETAIL, which is a page and not a fragment.
  # Without target="_top" Turbo looks for this frame in the detail response,
  # does not find one, and renders "Content missing" instead of navigating.
  test "the frame targets the top level so a row can navigate" do
    succeeded

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    frame = response.body[/<turbo-frame[^>]*id="#{DeploysController::FRAME}"[^>]*>/o]

    assert_not_nil frame
    assert_includes frame, 'target="_top"'
  end

  # An icon-only rail's label is the ONLY thing naming the tab, so it gets two
  # ways to appear: a drawn tooltip on hover, and the native `title` that still
  # works if a stylesheet fails to load.
  test "each rail item carries a hover tooltip and a native one" do
    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    rail = response.body[%r{<nav[^>]*Deploys sections.*?</nav>}m]

    assert_not_nil rail
    assert_includes rail, %(title="Repositories")
    assert_includes rail, %(aria-label="Repositories")

    # The tooltip is DECORATION: the accessible name is on the link above, and
    # announcing it twice is what `aria-describedby` would have bought.
    assert_includes rail, %(role="tooltip" aria-hidden="true")
    assert_not_includes rail, "aria-describedby"

    # A NAMED group — the unnamed one is the sidebar's collapsed state, and
    # sharing it would pop every tooltip on the page at once.
    assert_includes rail, "group-hover/rail:opacity-100"

    # And it points at the icon.
    assert_includes rail, "rotate-45"
  end

  # ── the filters ────────────────────────────────────────────────────────

  # `?status=failed` typed by hand or carried by a link has to work, not only
  # `?status[]=failed` from the dropdown. `params.permit(status: [])` drops the
  # scalar silently, which is why nothing here is permitted.
  test "a scalar status filter applies, not only an array one" do
    ok = succeeded(sha: "aaa111aaa111")
    bad = failed(sha: "bbb222bbb222")

    get deploys_deployments_path(org_id: ACME, server_key: @server.key, status: "failed")

    assert_includes response.body, bad.short_sha
    assert_not_includes response.body, ok.short_sha
  end

  test "the search box matches the commit message and the sha" do
    hit = succeeded(sha: "aaa111aaa111", message: "Bump the redis pool")
    miss = succeeded(sha: "bbb222bbb222", message: "Unrelated change")

    get deploys_deployments_path(org_id: ACME, server_key: @server.key, q: "redis")

    assert_includes response.body, hit.short_sha
    assert_not_includes response.body, miss.short_sha
  end

  # The window is a two-element ARRAY, not a Range. Passing it straight to
  # `where` builds `created_at IN (from, until)` — matching the two boundary
  # instants and nothing between them, which silently returned an empty
  # history for every default page load.
  test "the default range includes recent deployments" do
    recent = succeeded(sha: "aaa111aaa111")

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_includes response.body, recent.short_sha
  end

  test "range=all drops the date clause entirely" do
    old = succeeded(sha: "aaa111aaa111")
    old.update_columns(created_at: 2.years.ago)

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_not_includes response.body, old.short_sha

    get deploys_deployments_path(org_id: ACME, server_key: @server.key, range: "all")

    assert_includes response.body, old.short_sha
  end

  # The dropdown is a CHECKBOX GROUP. Posting under a scalar name sends only
  # the last box ticked, so the menu would look like it applied and quietly
  # filter by one value.
  test "the status and repository menus post as arrays" do
    succeeded

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_match(/name="status\[\]"/, response.body)
    assert_match(/name="repo\[\]"/, response.body)
  end

  # Without a bound event the auto-submit controller never fires and the whole
  # bar does nothing — which is exactly what it did. `commit` and not `change`,
  # so the menu applies on close instead of reloading the frame under itself
  # after every tick.
  test "the filter form submits when a menu commits" do
    succeeded

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    # Phlex does not escape `>` inside an attribute value, so the arrow is
    # literal in the markup — not `&gt;`.
    assert_includes response.body, "ds-multiselect:commit->auto-submit#submit"
  end

  test "a multi-value filter applies both values" do
    a = failed(sha: "aaa111aaa111")
    b = succeeded(sha: "bbb222bbb222")
    c = skipped(sha: "ccc333ccc333")

    get deploys_deployments_path(org_id: ACME, server_key: @server.key,
      status: %w[failed succeeded])

    assert_includes response.body, a.short_sha
    assert_includes response.body, b.short_sha
    assert_not_includes response.body, c.short_sha
  end

  # TimeRangeFilter emits one hidden input per key with `value.to_s`, so an
  # Array would ride along as a literal `["failed"]`. Joined with a comma
  # instead, which the reading side splits.
  test "a comma-joined filter survives a range change" do
    a = failed(sha: "aaa111aaa111")
    succeeded(sha: "bbb222bbb222")

    get deploys_deployments_path(org_id: ACME, server_key: @server.key, status: "failed,skipped")

    assert_includes response.body, a.short_sha
    assert_not_includes response.body, "bbb222b"

    # And the range form carries it forward in that same shape.
    # Comma-joined and whole, not one value per hidden input.
    assert_includes response.body, %(<input type="hidden" name="status" value="failed,skipped">)
  end

  # ── cursor paging ──────────────────────────────────────────────────────

  # An offset page two shifts under the reader: deploys arrive while they are
  # looking, and OFFSET re-shows rows they already read. A cursor names a ROW.
  test "paging walks older without repeating a row" do
    # Distinct in the FIRST SEVEN characters: the table renders `short_sha`,
    # so shas differing only in their tail would all match every assertion —
    # the first version of this test "passed" thirty-five rows onto one page.
    shas = (1..(DeploymentsData::PER_PAGE + 5)).map do |i|
      d = succeeded(sha: format("%07x", i * 4919) + "aaaaa")
      d.update_columns(created_at: i.minutes.ago)
      d.short_sha
    end

    assert_equal shas.uniq.size, shas.size, "the fixture shas collide"

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    first_page = shas.select { |s| response.body.include?(s) }

    assert_equal DeploymentsData::PER_PAGE, first_page.size

    cursor = Deployment.recent.offset(DeploymentsData::PER_PAGE - 1).first.cursor

    get deploys_deployments_path(org_id: ACME, server_key: @server.key, after: cursor)

    second_page = shas.select { |s| response.body.include?(s) }

    assert_empty(first_page & second_page, "a row appeared on both pages")
  end

  # A hand-edited cursor must fall back to the newest page, not raise.
  test "a nonsense cursor is ignored rather than fatal" do
    succeeded

    get deploys_deployments_path(org_id: ACME, server_key: @server.key, after: "not-a-cursor")

    assert_response :success
  end

  # ── the states ─────────────────────────────────────────────────────────

  test "a failed deployment shows the reason" do
    deployment = Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: "bbb2222bbb",
      status: "failed", error: "the build did not compile"
    )

    get deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)

    assert_response :success
    assert_includes response.body, "the build did not compile"
  end

  test "a skipped deployment explains itself without reading as a failure" do
    deployment = Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: "bbb2222bbb",
      status: "skipped", details: {"skipped_reason" => "nothing matched this push"}
    )

    get deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)

    assert_response :success
    assert_match(/nothing was deployed/i, response.body)
    assert_match(/nothing matched this push/i, response.body)
    assert_no_match(/did not complete/i, response.body)
  end

  # ── the gates ──────────────────────────────────────────────────────────

  test "a plan without the deploy plane does not reach the history" do
    free_tier!

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_redirected_to server_root_path(org_id: ACME, server_key: @server.key)
  end

  test "a member does not reach the history" do
    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_not_equal 200, response.status
  end

  private

  def succeeded(sha: "abc1234abc", resources: [], message: "Ship it")
    Deployment.create!(
      org: @org, server: @server, repo: "acme/api", ref: "refs/heads/main", sha: sha,
      status: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago,
      details: {"resources" => resources, "commit_message" => message}
    )
  end

  def skipped(sha: "ccc3333ccc")
    Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: sha, status: "skipped",
      details: {"skipped_reason" => "nothing matched"}
    )
  end

  def failed(sha: "bbb2222bbb")
    Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: sha,
      status: "failed", error: "the build did not compile"
    )
  end

  # The Repositories tab needs an integration to render anything but the
  # connect card.
  def connect_github!
    Integration::Record.find_or_create_by!(
      org: @org, provider: "github", external_id: "9001"
    ) { |r|
      r.name = "GitHub"
      r.status = "active"
    }
  end

  def saas!
    Rails.application.config.x.license = LicenseToken.new(
      status: :valid,
      claims: {"sub" => "acme", "tier" => "unlimited", "exp" => 90.days.from_now.to_i}
    )
  end

  def free_tier!
    Rails.application.config.x.license = LicenseToken.new(status: :none)
  end
end
