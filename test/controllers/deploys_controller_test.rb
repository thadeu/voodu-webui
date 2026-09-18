# frozen_string_literal: true

require "test_helper"

# The Deploys screen: the four states it must tell apart, and the two gates.
#
# The states matter more than they look. Each one sends the operator somewhere
# different — a firewall, a text editor, a commit, a command on the box — and a
# screen that collapses two of them sends half its readers to the wrong place.
# The pairing tested hardest is "the box did not answer" against "there is no
# config", because saying the second when the first is true makes somebody look
# for a file that never moved.
class DeploysControllerTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"
  INSTALLATION = "9001"
  REPO = "acme/api"

  setup do
    @licensed = Rails.application.config.x.license
    @env = ENV.to_hash.slice("GITHUB_APP_ID", "GITHUB_APP_SLUG", "GITHUB_APP_PRIVATE_KEY")

    saas!
    configure_app!
    Rails.cache.clear

    @org = orgs(:acme)
    @server = servers(:alpha)
  end

  teardown do
    Rails.application.config.x.license = @licensed
    %w[GITHUB_APP_ID GITHUB_APP_SLUG GITHUB_APP_PRIVATE_KEY].each { |key| ENV.delete(key) }
    @env.each { |key, value| ENV[key] = value }
    Rails.cache.clear
  end

  # ── the gates ──────────────────────────────────────────────────────────

  test "the screen renders for an admin on a plan that includes the deploy plane" do
    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_includes response.body, "Deploys"
  end

  # The nav item is not what enforces this. Hiding a door whose endpoint still
  # answers is not a control.
  test "a plan without the deploy plane does not reach the screen" do
    free_tier!

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_redirected_to server_root_path(org_id: ACME, server_key: @server.key)
    assert_match(/not part of this plan/i, flash[:alert])
  end

  # The nav item asks BOTH questions the endpoint asks. An admin on a plan
  # without the deploy plane holds manage_deploys and still cannot get in, so a
  # capability-only check would draw a door that answers "not part of this
  # plan".
  test "the sidebar offers Deploys on the plan that includes it" do
    get server_root_path(org_id: ACME, server_key: @server.key)

    assert_includes response.body, deploys_repositories_path(org_id: ACME, server_key: @server.key)
  end

  test "the sidebar does not offer Deploys on a plan without it" do
    free_tier!

    get server_root_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_not_includes response.body, deploys_repositories_path(org_id: ACME, server_key: @server.key)
  end

  test "a member does not reach the screen" do
    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_not_equal 200, response.status
  end

  # ── not connected ──────────────────────────────────────────────────────

  test "with no integration the screen offers to connect rather than showing an empty list" do
    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_includes response.body, "Connect GitHub"
  end

  test "with no App configured at all the screen says so instead of offering a dead button" do
    ENV.delete("GITHUB_APP_ID")

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_match(/no GitHub App configured/i, response.body)
  end

  # ── the four states ────────────────────────────────────────────────────

  # An unreachable box is NOT an empty configuration. The default WebMock stub
  # times out every non-local host, so this is the real path.
  test "an unreachable server says it could not ask, not that there is no config" do
    connect!

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/could not read this repository/i, response.body)
    assert_no_match(/No trigger file in this repository/i, response.body)
  end

  # A 404 is not an outage and not a missing repository — it is a controller
  # built before the deploy plane existed. Saying "could not read this
  # repository" sends the operator to look at GitHub, or at their firewall,
  # for something neither one did.
  # THE CALL THAT ANSWERS THIS IS `deploy/triggers`, which takes no GitHub
  # token and names no repository. A 404 from it means one thing: the route is
  # not on that controller.
  test "a controller without the deploy plane says so, not that the repo failed" do
    connect!

    WebMock.stub_request(:get, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/triggers})
      .to_return(status: 404, body: "404 page not found", headers: {"Content-Type" => "text/plain"})

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/without the deploy plane/i, response.body)
    assert_match(/upgrade/i, response.body)
    assert_no_match(/could not read this repository/i, response.body)
  end

  # THE BUG THIS REPLACED, and it cost a real debugging session: a 404 from
  # `deploy/manifests` is GITHUB's — a repository or ref the token cannot see —
  # and reading it as "no deploy plane" told the operator to upgrade a box that
  # was already upgraded, while the real problem was somewhere else.
  test "a GitHub 404 is not read as a missing deploy plane" do
    connect!
    stub_triggers([])

    WebMock.stub_request(:get, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/manifests})
      .to_return(
        status: 404,
        body: {status: "error", error: "GitHub has no such repository or ref"}.to_json,
        headers: {"Content-Type" => "application/json"}
      )

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_no_match(/without the deploy plane/i, response.body)

    # And it says what the box actually said, rather than a guess.
    assert_match(/could not read this repository/i, response.body)
    assert_match(/no such repository or ref/i, response.body)
  end

  # An empty `.voodu/` is the NORMAL state the day somebody connects a
  # repository, and it is this screen's only teaching moment: the reader has
  # one question — what do I write — and the answer is four lines they will
  # never guess. Sending them to documentation here sends them away at the
  # moment they were ready to act.
  test "a repository with no trigger file gets a worked example, not an error" do
    connect!
    stub_manifests(files: [])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/add a trigger file to start deploying/i, response.body)
    assert_includes response.body, ".voodu/deploy.yml"

    # About THEIR repository: the default branch we already know, not a
    # generic `main` they would have to translate before pasting.
    assert_includes response.body, "branches: [main]"
    assert_includes response.body, REPO
  end

  # One bad file must not take the others with it: the operator came to see
  # what deploys, and a page that renders nothing tells them less than the box
  # already knew.
  test "an invalid file reports its own error and the valid ones still render" do
    connect!
    stub_manifests(files: [
      {"path" => ".voodu/broken.yml", "error" => "unknown field \"branch\""},
      {"path" => ".voodu/api.yml", "spec" => {"name" => "API", "on" => {"push" => {"branches" => ["main"]}}}}
    ])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_includes response.body, "unknown field"
    assert_includes response.body, ".voodu/api.yml"
  end

  # The viewer opens on a file the box could USE. A repository whose first file
  # alphabetically is broken should not open on the broken one.
  test "the viewer opens on a usable file rather than the first one" do
    connect!
    stub_manifests(files: [
      {"path" => ".voodu/aaa.yml", "error" => "boom"},
      {"path" => ".voodu/zzz.yml", "spec" => {"name" => "Zed", "apply" => {"file" => "voodu.hcl"}}}
    ])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/as the box read it/i, response.body)
  end

  # A valid file with no trigger deploys nothing, and that is the state most
  # likely to be mistaken for a bug. It gets the form that fixes it.
  # The list is per server; the installation is per account. A database box
  # must not present every app repository as if something were set up for
  # it — those fold under "Available from GitHub", and the head counts only
  # what deploys here.
  test "repositories that do not deploy here fold under Available from GitHub" do
    connect!(list_repo: false)
    stub_github_repos_returning([REPO, "acme/other"])
    integration = Integration::Record.active.find_by!(org: @org, provider: "github")
    integration.add_repo!(repo: "acme/other", server_id: @server.id, trigger_id: "t9")

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_select "details summary", text: /Available from GitHub/
    assert_select "details a[title='#{REPO}']", count: 1
    assert_select "details a[title='acme/other']", count: 0
    assert_select "details[open]", count: 0
  end

  # The head carries the GitHub-side chores once connected: the installation
  # page (repositories, and the uninstall in its danger zone) and the account
  # picker for a second account. Without a connection there is nothing to
  # manage, and the only affordance is Connect.
  test "the head links to the installation on GitHub, to connect another account, and to uninstall" do
    connect!(list_repo: false)
    integration = Integration::Record.active.find_by!(org: @org, provider: "github")
    integration.update!(html_url: "https://github.com/organizations/acme/settings/installations/4242")

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_select "a[href='https://github.com/organizations/acme/settings/installations/4242'][target=_blank]", minimum: 2
    assert_select "a[href=?]", connect_github_path(org_id: ACME, server_key: @server.key), text: /Connect another/
    assert_includes response.body, "Uninstall"
  end

  test "the head has no GitHub links before a connection exists" do
    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_select "a", text: /Connect another/, count: 0
    refute_includes response.body, "Uninstall"
  end

  test "with nothing deploying here the available section opens by itself" do
    connect!(list_repo: false)

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_includes response.body, "Nothing deploys to this server yet."
    assert_select "details[open] summary", text: /Available from GitHub/
  end

  test "a repository with no trigger on the box offers to connect it" do
    connect!
    stub_manifests(files: [{"path" => ".voodu/api.yml", "spec" => {"name" => "API"}}])
    stub_triggers([])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/not deploying here yet/i, response.body)
    assert_includes response.body, connect_repo_deploys_path(org_id: ACME, server_key: @server.key)
  end

  # The screen says what the button does. That the console may widen what a box
  # accepts is a deliberate trade, and a form that performed it silently would
  # be the loss without the trade.
  test "the connect form says the trigger lands on the server and is auditable" do
    connect!
    stub_manifests(files: [{"path" => ".voodu/api.yml", "spec" => {"name" => "API"}}])
    stub_triggers([])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_match(/creates a trigger on/i, response.body)
    assert_match(/activity trail/i, response.body)
  end

  test "a repository with a trigger shows what the box authorized instead" do
    connect!
    stub_manifests(files: [{"path" => ".voodu/api.yml", "spec" => {"name" => "API"}}])
    stub_triggers([{"id" => "t1", "repo" => REPO, "branch" => "main", "enabled" => true,
                    "allow_scopes" => ["web"]}])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/Trigger enabled/i, response.body)
    assert_no_match(/No trigger on this server yet/i, response.body)
  end

  # Each block says what KIND of thing it is, and the tones are not
  # interchangeable: "no trigger yet" is something to fix (amber), "no file
  # yet" is the expected state on day one (blue), "a file was refused" is the
  # one thing that should catch the eye (red).
  #
  # Pinned because the failure is silent — everything renders, and the page
  # just stops helping the reader sort it.
  test "the panel distinguishes what to fix from what to know" do
    connect!
    stub_triggers([])
    stub_manifests(files: [
      {"path" => ".voodu/broken.yml", "error" => "unknown field"},
      {"path" => ".voodu/api.yml", "spec" => {"name" => "API"}}
    ])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success

    # Something to fix, and something that failed.
    assert_includes response.body, "border-l-voodu-amber"
    assert_includes response.body, "border-l-voodu-red"

    # And none of THE CALLOUTS as a filled card, which is what made every block
    # shout. Scoped to the callouts: the layout carries a confirm dialog whose
    # amber theme class sits inert on every page, and asserting against the
    # whole body catches that instead.
    callouts = response.body.scan(/<div class="[^"]*border-l-voodu-[^"]*"/)

    assert_operator callouts.size, :>=, 2, "expected the panel to draw callouts"
    assert(callouts.none? { |n| n.include?("-dim") && !n.include?("red") },
      "only danger keeps a fill: #{callouts.inspect}")
  end

  # An empty `.voodu/` on the day somebody connects a repository is the
  # EXPECTED state, not a problem they caused. Amber here would tell them
  # something is wrong when nothing is.
  test "an empty repository is informed, not warned" do
    connect!
    stub_triggers([{"id" => "t1", "repo" => REPO, "branch" => "main", "enabled" => true}])
    stub_manifests(files: [])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/add a trigger file/i, response.body)
    assert_includes response.body, "border-l-voodu-blue"
    assert_not_includes response.body, "border-l-voodu-amber"
  end

  # ── preflight ──────────────────────────────────────────────────────────

  # The box's preflight takes a TRIGGER ID: the four questions are about an
  # authorization, so there is nothing to ask before one exists. Offering the
  # button beside "Not deploying here yet" put two contradictory things on
  # screen and made the operator click one to be told to use the other.
  test "a repository with no trigger is not offered a preflight" do
    connect!
    stub_manifests(files: [{"path" => ".voodu/api.yml", "spec" => {"name" => "API"}}])
    stub_triggers([])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/not deploying here yet/i, response.body)
    assert_no_match(/run preflight/i, response.body)
  end

  # It is a button, not something that runs on render: the box has to reach
  # GitHub to answer, and spending that on every card click is not what a
  # preflight is for.
  test "the panel offers a preflight rather than running one" do
    connect!
    stub_manifests(files: [{"path" => ".voodu/api.yml", "spec" => {"name" => "API"}}])
    stub_triggers([{"id" => "t1", "repo" => REPO, "branch" => "main", "enabled" => true}])

    get deploys_repositories_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/Run preflight/i, response.body)
    assert_no_match(/Ready to deploy/i, response.body)
  end

  # Four answers, not one boolean. Each failure has a different fix, and
  # "preflight failed" names none of them.
  test "a preflight reports each check separately" do
    connect!
    stub_triggers([{"id" => "t1", "repo" => REPO, "branch" => "main", "enabled" => true}])
    stub_preflight(ok: false, checks: [
      {"name" => "trigger_enabled", "ok" => true},
      {"name" => "container_runtime", "ok" => true},
      {"name" => "github_reachable", "ok" => true},
      {"name" => "manifests_found", "ok" => false,
       "detail" => "no .voodu/**/*.yml on main — add one to declare when to deploy"}
    ])

    get preflight_deploys_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/1 of 4 checks failed/i, response.body)
    assert_match(/A usable trigger file exists/i, response.body)
    assert_match(/The box reached GitHub/i, response.body)
    assert_includes response.body, "add one to declare when to deploy"
  end

  test "a passing preflight says the deploy is ready" do
    connect!
    stub_triggers([{"id" => "t1", "repo" => REPO, "branch" => "main", "enabled" => true}])
    stub_preflight(ok: true, checks: [
      {"name" => "trigger_enabled", "ok" => true},
      {"name" => "container_runtime", "ok" => true},
      {"name" => "github_reachable", "ok" => true},
      {"name" => "manifests_found", "ok" => true}
    ])

    get preflight_deploys_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/Ready to deploy/i, response.body)
  end

  # There is nothing to preflight before a trigger exists, and the box's
  # endpoint says so too. Saying it beats a button that answers "no trigger".
  test "a repository with no trigger says there is nothing to preflight yet" do
    connect!
    stub_triggers([])

    get preflight_deploys_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/no trigger for #{Regexp.escape(REPO)}/io, response.body)
  end

  # An unreachable box is not a failing preflight: one means the checks ran and
  # said no, the other means nobody answered.
  test "an unreachable server does not read as a failed preflight" do
    connect!

    get preflight_deploys_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_response :success
    assert_match(/could not run the preflight/i, response.body)

    # NOT "there is no trigger yet". `trigger_for` answers nil both when the
    # box has none and when the box never answered, and saying the first when
    # the second is true sends somebody to create what already exists.
    assert_no_match(/no trigger for/i, response.body)
    assert_no_match(/checks failed/i, response.body)
  end

  test "a preflight for a repository this server does not list is refused" do
    connect!(list_repo: false)

    get preflight_deploys_path(org_id: ACME, server_key: @server.key, repo: "acme/somewhere-else")

    assert_redirected_to deploys_repositories_path(org_id: ACME, server_key: @server.key)
  end

  test "a plan without the deploy plane does not reach the preflight either" do
    connect!
    free_tier!

    get preflight_deploys_path(org_id: ACME, server_key: @server.key, repo: REPO)

    assert_redirected_to server_root_path(org_id: ACME, server_key: @server.key)
  end

  # ── connecting a repository ────────────────────────────────────────────

  # THE WRITE THIS SCREEN EXISTS FOR, and the order of its two halves is the
  # design: the trigger lands on the box FIRST, then our listing entry.
  test "connecting creates the trigger on the box and lists the repository here" do
    integration = connect!(list_repo: false)
    create = stub_trigger_create(id: "trg-new")

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "main", allow_scopes: "prod, staging"}

    assert_requested create

    entry = integration.reload.repos_for_server(@server).find { |e| e.matches?(REPO) }

    assert_not_nil entry, "the repository was not listed for this server"
    assert_equal "trg-new", entry.trigger_id
  end

  test "the scopes field accepts commas and newlines, deduped" do
    connect!(list_repo: false)
    body = nil

    WebMock.stub_request(:post, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/triggers})
      .with { |req| body = req.body }
      .to_return(status: 201, body: {status: "ok", data: {id: "trg-new"}}.to_json,
        headers: {"Content-Type" => "application/json"})

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "main", allow_scopes: "prod,\nstaging\nprod"}

    assert_equal ["prod", "staging"], JSON.parse(body)["allow_scopes"]
  end

  # A listing entry naming a trigger that was never created is worse than no
  # entry: every push to that repository would queue a deployment that fails at
  # the box, under a screen saying the repository is connected.
  test "a trigger the box refused leaves nothing listed here" do
    integration = connect!(list_repo: false)

    WebMock.stub_request(:post, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/triggers})
      .to_return(status: 403, body: {status: "error", error: "insufficient scope"}.to_json,
        headers: {"Content-Type" => "application/json"})

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "main", allow_scopes: "prod"}

    assert_empty integration.reload.repos_for_server(@server)
    assert_match(/deploy scope/i, flash[:alert])
  end

  test "an unreachable server leaves nothing listed here" do
    integration = connect!(list_repo: false)

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "main", allow_scopes: "prod"}

    assert_empty integration.reload.repos_for_server(@server)
    assert_match(/did not answer/i, flash[:alert])
  end

  # The box refuses an empty list too, but its message says "allow_scopes is
  # required" and the person is looking at a field labeled Scopes.
  test "connecting with no scopes is refused before the box is called" do
    connect!(list_repo: false)
    create = stub_trigger_create

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "main", allow_scopes: "  , "}

    assert_not_requested create
    assert_match(/at least one scope/i, flash[:alert])
  end

  test "connecting with no branch is refused and says what the branch is for" do
    connect!(list_repo: false)
    create = stub_trigger_create

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "", allow_scopes: "prod"}

    assert_not_requested create
    assert_match(/descend from/i, flash[:alert])
  end

  # Checked before the box is called: otherwise the trigger would be created
  # on the server and the local write would raise, leaving an authorization
  # nothing points at.
  test "connecting with no GitHub integration touches the box at all" do
    create = stub_trigger_create

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "main", allow_scopes: "prod"}

    assert_not_requested create
    assert_match(/connect github/i, flash[:alert])
  end

  # ── disconnecting ──────────────────────────────────────────────────────

  # The reverse order: our entry first, because that is what stops the next
  # push from queueing anything.
  test "disconnecting unlists the repository and deletes the trigger" do
    integration = connect!
    removal = WebMock.stub_request(:delete, %r{/api/pat/v1/deploy/triggers/t1})
      .to_return(status: 200, body: {status: "ok"}.to_json,
        headers: {"Content-Type" => "application/json"})

    delete disconnect_repo_deploys_path(org_id: ACME, server_key: @server.key), params: {repo: REPO}

    assert_requested removal
    assert_empty integration.reload.repos_for_server(@server)
  end

  # An orphan trigger fires nothing, so the disconnect stands — but the
  # operator is told there is something left on their box, with the command.
  test "a trigger the box would not delete leaves the repository disconnected and says so" do
    integration = connect!

    WebMock.stub_request(:delete, %r{/api/pat/v1/deploy/triggers/t1})
      .to_return(status: 500, body: {status: "error", error: "boom"}.to_json,
        headers: {"Content-Type" => "application/json"})

    delete disconnect_repo_deploys_path(org_id: ACME, server_key: @server.key), params: {repo: REPO}

    assert_empty integration.reload.repos_for_server(@server)
    assert_match(/still on/i, flash[:alert])
    assert_includes flash[:alert], "vd deploy trigger delete t1"
  end

  # Already gone from the box is the outcome the operator asked for, not an
  # error to report at them.
  test "a trigger already gone from the box disconnects quietly" do
    connect!

    WebMock.stub_request(:delete, %r{/api/pat/v1/deploy/triggers/t1})
      .to_return(status: 404, body: {status: "error", error: "no trigger"}.to_json,
        headers: {"Content-Type" => "application/json"})

    delete disconnect_repo_deploys_path(org_id: ACME, server_key: @server.key), params: {repo: REPO}

    assert_nil flash[:alert]
    assert_match(/no longer deploys/i, flash[:notice])
  end

  test "a member cannot connect a repository by posting directly" do
    connect!(list_repo: false)
    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")

    create = stub_trigger_create

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "main", allow_scopes: "prod"}

    assert_not_requested create
  end

  test "a plan without the deploy plane cannot connect a repository" do
    connect!(list_repo: false)
    free_tier!

    create = stub_trigger_create

    post connect_repo_deploys_path(org_id: ACME, server_key: @server.key),
      params: {repo: REPO, branch: "main", allow_scopes: "prod"}

    assert_not_requested create
  end

  # ── the cards ──────────────────────────────────────────────────────────

  # Authorized-but-not-pointed-here is shown rather than hidden: "I gave you
  # access and it is not here" is the confusing state, and the fix is one card
  # away.
  test "a repository authorized on GitHub but not pointed at this server still gets a card" do
    connect!(list_repo: false)

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_includes response.body, REPO
    assert_match(/Not connected/i, response.body)
  end

  test "a repository pointed at this server is marked as deploying here" do
    connect!

    get deploys_repositories_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_match(/Deploys here/i, response.body)
  end

  # The listing is cached because it changes on github.com, where nothing tells
  # us. Refresh is how somebody's own click stops meaning "wait five minutes".
  # A real store for this one test. The suite runs on :null_store, where a
  # cache assertion passes or fails for reasons that have nothing to do with
  # the code being tested.
  test "refresh drops the cached repository listing" do
    with_memory_cache do
      connect!
      get deploys_repositories_path(org_id: ACME, server_key: @server.key)

      integration = Integration::Record.find_by(org: @org, provider: "github")

      assert Rails.cache.exist?("deploys:repos:#{integration.id}"),
        "the listing should be cached after a render"

      post refresh_deploys_path(org_id: ACME, server_key: @server.key)

      assert_redirected_to deploys_repositories_path(org_id: ACME, server_key: @server.key)
      assert_not Rails.cache.exist?("deploys:repos:#{integration.id}")
    end
  end

  # ── the play button ────────────────────────────────────────────────────

  test "dispatching a held deployment queues it again as a dispatch" do
    deployment = held_deployment

    assert_enqueued_with(job: DeployRunJob, args: [deployment.id]) do
      post dispatch_deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)
    end

    assert_redirected_to deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)
    deployment.reload
    assert_equal "queued", deployment.status
    assert deployment.dispatch?
  end

  test "a deployment with nothing held refuses to dispatch" do
    deployment = held_deployment(held: [])

    assert_no_enqueued_jobs(only: DeployRunJob) do
      post dispatch_deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)
    end

    assert_redirected_to deploys_deployment_path(org_id: ACME, server_key: @server.key, id: deployment.id)
  end

  test "the deployments table shows a play button only on a held row" do
    held_deployment

    get deploys_deployments_path(org_id: ACME, server_key: @server.key)

    assert_response :success
    assert_select "form[action*='/dispatch']", 1
  end

  def held_deployment(held: ["API"])
    Deployment.create!(
      org: @org, server: @server, repo: REPO, ref: "refs/heads/main", sha: "abc1234abc1234",
      trigger_id: "t1", status: "held", delivery_id: SecureRandom.uuid,
      finished_at: Time.current, details: {"held" => held}
    )
  end

  private

  def with_memory_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    yield
  ensure
    Rails.cache = previous
  end

  KEY = OpenSSL::PKey::RSA.generate(2048).to_pem

  def configure_app!
    ENV["GITHUB_APP_ID"] = "12345"
    ENV["GITHUB_APP_SLUG"] = "voodu-test"
    ENV["GITHUB_APP_PRIVATE_KEY"] = KEY
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

  # connect! — an integration, the GitHub listing stubbed, and (by default) the
  # repository pointed at this server.
  def connect!(list_repo: true)
    integration = Integration::Record.create!(
      org: @org, name: "GitHub", provider: "github",
      external_id: INSTALLATION, status: "active"
    )
    integration.add_repo!(repo: REPO, server_id: @server.id, trigger_id: "t1") if list_repo

    stub_github_repos
    integration
  end

  def stub_github_repos_returning(names)
    WebMock.stub_request(:get, %r{https://api\.github\.com/installation/repositories})
      .to_return(status: 200, body: {
        total_count: names.size,
        repositories: names.map { |name| {full_name: name, default_branch: "main", private: false} }
      }.to_json, headers: {"Content-Type" => "application/json"})
  end

  def stub_github_repos
    WebMock.stub_request(:post, "https://api.github.com/app/installations/#{INSTALLATION}/access_tokens")
      .to_return(status: 201, body: {token: "ghs_test"}.to_json,
        headers: {"Content-Type" => "application/json"})

    WebMock.stub_request(:get, %r{https://api\.github\.com/installation/repositories})
      .to_return(status: 200, body: {
        total_count: 1,
        repositories: [{full_name: REPO, default_branch: "main", private: true}]
      }.to_json, headers: {"Content-Type" => "application/json"})
  end

  def stub_manifests(files:, stats: {"files" => 12, "bytes" => 4096})
    stub_triggers([]) unless @triggers_stubbed

    WebMock.stub_request(:get, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/manifests})
      .to_return(status: 200, body: {
        status: "ok",
        data: {repo: REPO, ref: "main", commit: "abc1234", stats: stats, files: files}
      }.to_json, headers: {"Content-Type" => "application/json"})
  end

  def stub_preflight(ok:, checks:)
    WebMock.stub_request(:get, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/preflight})
      .to_return(status: 200, body: {
        status: "ok",
        data: {trigger: "t1", repo: REPO, branch: "main", ok: ok, checks: checks}
      }.to_json, headers: {"Content-Type" => "application/json"})
  end

  def stub_trigger_create(id: "trg-new")
    WebMock.stub_request(:post, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/triggers})
      .to_return(status: 201, body: {status: "ok", data: {id: id, repo: REPO, branch: "main"}}.to_json,
        headers: {"Content-Type" => "application/json"})
  end

  def stub_triggers(triggers)
    @triggers_stubbed = true

    WebMock.stub_request(:get, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/triggers})
      .to_return(status: 200, body: {status: "ok", data: {triggers: triggers}}.to_json,
        headers: {"Content-Type" => "application/json"})
  end
end
