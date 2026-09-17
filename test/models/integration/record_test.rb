# frozen_string_literal: true

require "test_helper"

class Integration::RecordTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @org = orgs(:acme)
    @server = servers(:alpha)
    @integration = create_integration
  end

  def build_integration(org: @org, external_id: "111")
    Integration::Record.new(
      org: org, name: "GitHub", provider: "github",
      external_id: external_id, account_login: "acme-corp"
    )
  end

  def create_integration(**) = build_integration(**).tap(&:save!)

  # The state in the instant after the GitHub callback: connected, and nothing
  # configured. A row per repository could not represent it without a row whose
  # repo is null, which would mean something different from its siblings.
  test "a fresh connection has no repositories and is still valid" do
    assert @integration.valid?
    assert_empty @integration.repos
    assert_equal "acme-corp", @integration.account_login
  end

  test "an unknown provider is refused" do
    record = Integration::Record.new(org: @org, provider: "bitbucket", external_id: "1")

    assert_not record.valid?
  end

  # A second connection is not a second connection — it is the same one written
  # twice, and two records that must agree is a way for them to disagree.
  # An org may connect SEVERAL GitHub accounts: acme-corp feeding one server
  # and acme-labs feeding another. Refusing the second would be a limit nobody
  # could explain.
  test "an org may connect several GitHub accounts" do
    assert build_integration(external_id: "222").valid?, "a second GitHub account is a second installation"
  end

  test "the same installation cannot be recorded twice for one org" do
    assert_not build_integration(external_id: "111").valid?
  end

  test "another org may connect the same GitHub account" do
    assert build_integration(org: orgs(:globex), external_id: "111").valid?
  end

  test "adding a repository stores the bridge the webhook needs" do
    entry = @integration.add_repo!(repo: "  ACME/Web  ", server_id: @server.id, trigger_id: "a3f91b")

    assert_equal "acme/web", entry.repo, "GitHub compares these case-insensitively"

    reloaded = @integration.reload

    assert_equal 1, reloaded.repos.size
    assert_equal "a3f91b", reloaded.repo_for("Acme/WEB").trigger_id
  end

  # The same repository may deploy to two servers — a staging box and a
  # production one — and adding it twice to the SAME server replaces rather
  # than duplicates.
  test "one entry per repository per server" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "one")
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "two")

    assert_equal 1, @integration.reload.repos.size
    assert_equal "two", @integration.repos.first.trigger_id

    @integration.add_repo!(repo: "acme/web", server_id: servers(:beta).id, trigger_id: "three")

    assert_equal 2, @integration.reload.repos.size
  end

  test "an incomplete entry is refused on write" do
    assert_raises(ArgumentError) do
      @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "")
    end
  end

  # The list is a blob with no database constraints, so a half-written entry is
  # reachable. A screen that 500s because one row is malformed is worse than a
  # screen missing one row.
  test "a malformed entry already in the blob is dropped on read" do
    @integration.update!(config: {"repos" => [
      {"repo" => "acme/web", "server_id" => @server.id, "trigger_id" => "ok"},
      {"repo" => "acme/broken"},
      {"server_id" => 9, "trigger_id" => "x"}
    ]})

    assert_equal ["acme/web"], @integration.reload.repos.map(&:repo)
  end

  # The blob carries no foreign key, so a deleted server leaves an orphan. The
  # READ is what protects — cleanup on destroy can fail, and this cannot be
  # skipped by anything that asks the question.
  test "an entry pointing at a server that no longer exists is not deployable" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "a")
    @integration.add_repo!(repo: "acme/api", server_id: 999_999, trigger_id: "b")

    assert_equal 2, @integration.repos.size, "both are stored"
    assert_equal ["acme/web"], @integration.deployable_repos.map(&:repo)
  end

  # A server belonging to ANOTHER org is as good as gone: it is not this org's
  # to deploy to, and the read is where that is decided.
  test "an entry pointing at another org's server is not deployable" do
    foreign = servers(:beta)
    foreign.update!(org: orgs(:globex))

    @integration.add_repo!(repo: "acme/web", server_id: foreign.id, trigger_id: "a")

    assert_empty @integration.deployable_repos
  end

  test "removing a repository leaves the others" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "a")
    @integration.add_repo!(repo: "acme/api", server_id: @server.id, trigger_id: "b")

    @integration.remove_repo!(repo: "acme/web")

    assert_equal ["acme/api"], @integration.reload.repos.map(&:repo)
  end

  # An installation the customer removed on GitHub's side is history worth
  # keeping, and reconnecting should not mean rebuilding the repository list.
  test "revoking keeps the row and the list" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "a")

    @integration.revoke!

    assert_not @integration.active?
    assert_equal 1, @integration.reload.repos.size
    assert_empty Integration::Record.active.where(org: @org)
  end

  # A webhook arrives with no session, no org and no user — just an
  # installation id. Starting from the installation is what makes the tenant
  # scoping structural: a delivery never had a way to name another org.
  test "a delivery cannot reach another org's repository list" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "mine")

    globex = orgs(:globex)
    theirs = create_integration(org: globex, external_id: "222")
    beta = servers(:beta)
    beta.update!(org: globex)
    theirs.add_repo!(repo: "acme/web", server_id: beta.id, trigger_id: "theirs")

    targets = Integration::Record.for_delivery("github", "111", "acme/web")

    assert_equal ["mine"], targets.map(&:trigger_id),
      "the same repository name in another org must not be reachable"
  end

  # One repository may deploy to two servers, and both should fire.
  test "a delivery returns every matching target" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "prod")
    @integration.add_repo!(repo: "acme/web", server_id: servers(:beta).id, trigger_id: "staging")

    targets = Integration::Record.for_delivery("github", "111", "acme/web")

    assert_equal %w[prod staging], targets.map(&:trigger_id).sort
  end

  # THE bug `find_by` would have caused: the same GitHub account connected by
  # two of the customer's orgs produces two rows with the same external_id, and
  # picking one arbitrarily would silently drop the other org's deploys.
  test "one installation shared by two orgs delivers to both" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "first")

    globex = orgs(:globex)
    beta = servers(:beta)
    beta.update!(org: globex)

    second = create_integration(org: globex, external_id: "111")
    second.add_repo!(repo: "acme/web", server_id: beta.id, trigger_id: "second")

    targets = Integration::Record.for_delivery("github", "111", "acme/web")

    assert_equal %w[first second], targets.map(&:trigger_id).sort,
      "find_by would have returned one row and dropped the other org entirely"
  end

  test "a revoked integration is not delivered to" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "a")
    @integration.revoke!

    assert_empty Integration::Record.for_delivery("github", "111", "acme/web")
  end

  # A stale or foreign server_id in a blob has no foreign key to stop it. The
  # delivery read is the only thing between it and a deploy.
  test "a delivery skips an entry whose server is gone" do
    @integration.add_repo!(repo: "acme/web", server_id: 999_999, trigger_id: "orphan")

    assert_empty Integration::Record.for_delivery("github", "111", "acme/web")
  end

  # This is where "server A uses GitHub, server B does not" lives — and it is a
  # list, not a flag: a server with no entries does not use GitHub, and nothing
  # has to be switched off for that to be true.
  test "which repositories deploy to one server" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "a")
    @integration.add_repo!(repo: "acme/api", server_id: servers(:beta).id, trigger_id: "b")

    assert_equal ["acme/web"], @integration.repos_for_server(@server).map(&:repo)
    assert_equal ["acme/api"], @integration.repos_for_server(servers(:beta)).map(&:repo)

    # A server nobody listed does not use GitHub, and no flag had to be turned
    # off for that to be true.
    assert_empty @integration.repos_for_server(999_999)
  end

  # config is reassigned rather than mutated on write: ActiveRecord tracks the
  # attribute, and mutating the hash in place leaves it thinking nothing
  # changed — the write silently does nothing.
  test "a write actually persists" do
    @integration.add_repo!(repo: "acme/web", server_id: @server.id, trigger_id: "a")

    fresh = Integration::Record.find(@integration.id)

    assert_equal 1, fresh.repos.size
  end

  # THE price of keeping the list in a blob, and the reason add_repo! takes a
  # lock. Two people connecting two repositories at once do a read-modify-write
  # over the same field, and without the lock the second write overwrites the
  # first — one repository silently never deploys.
  #
  # `with_lock` and not optimistic locking: the loser of the race should WAIT,
  # not be told their click failed.
  test "two repositories added in parallel both survive" do
    integration = @integration
    server = @server
    other = servers(:beta)

    # SQLite serializes writers, so the lock is what makes the read-modify-write
    # atomic rather than merely ordered.
    threads = [
      Thread.new { Integration::Record.find(integration.id).add_repo!(repo: "acme/web", server_id: server.id, trigger_id: "a") },
      Thread.new { Integration::Record.find(integration.id).add_repo!(repo: "acme/api", server_id: other.id, trigger_id: "b") }
    ]

    threads.each(&:join)

    assert_equal %w[acme/api acme/web], integration.reload.repos.map(&:repo).sort,
      "a write lost the other one — the list is a blob, so add_repo! must lock"
  end
end
