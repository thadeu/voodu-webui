# frozen_string_literal: true

# DeploysData — what the Deploys screen renders, for ONE server.
#
# Per server and not per org, because that is where the decision lives: a
# customer may deploy their API box from GitHub and run their database box by
# hand. The GitHub INSTALLATION cannot be per server — GitHub allows one per
# account — so the per-server part is which repositories point at this box.
#
# ## Where each piece comes from, and what it costs
#
# | Piece | Source | Cost per render |
# | --- | --- | --- |
# | repository list | the GitHub installation | cached, REPOS_TTL |
# | which ones deploy here | our own `integrations.config` | a row we already have |
# | triggers | the box | one call |
# | YAML + verdict + stats | the box, which reads GitHub | one call, only for the repo the operator OPENED |
#
# The last line is the whole shape of the screen. Cards render from the cached
# list; nothing talks to a box until somebody opens a card. A screen that spent
# a call per card would be a screen that gets throttled the day a customer
# authorizes forty repositories.
#
# ## What this does NOT do
#
# It does not read YAML from GitHub and it does not validate YAML. The box
# already answered both, and a second opinion that disagrees is how a screen
# starts lying to the person reading it.
class DeploysData
  # Long enough that clicking between cards costs nothing, short enough that a
  # repository authorized on GitHub a minute ago shows up without anybody
  # having to know there is a cache. `refresh!` exists for the impatient.
  REPOS_TTL = 5.minutes

  # Where a repository declares its triggers. Must match triggerspec.Dir on the
  # Go side — the screen tells people where to put the file, and telling them
  # the wrong place is worse than not telling them.
  TRIGGER_DIR = ".voodu"

  # Repo — one card.
  #
  # `listed?` is the per-server decision: authorized on GitHub AND pointed at
  # this box. A repository the customer authorized but never pointed anywhere
  # is a card with no trigger, which is a state the screen names.
  Repo = Struct.new(:full_name, :default_branch, :private, :listed, :trigger_id) do
    def listed? = listed

    def private? = private

    def owner = full_name.to_s.split("/").first

    def name = full_name.to_s.split("/").last

    def html_url = "https://github.com/#{full_name}"
  end

  # Manifests — the box's answer about one repository.
  #
  # `unreachable` is a THIRD state beside "found files" and "found none", and
  # keeping it separate is the point: reporting "no trigger files" when we
  # could not ask sends an operator looking for a file that never moved.
  Manifests = Struct.new(
    :repo, :ref, :commit, :files, :stats, :truncated, :unreachable, :unsupported, :error
  ) do
    def unreachable? = unreachable

    # unsupported? — the box answered, and it has no deploy plane.
    #
    # A 404 here is NOT an outage and NOT a missing repository: it is a
    # controller built before these routes existed. Kept apart from
    # `unreachable?` because the two send an operator to completely different
    # places — one is "check the network or the repository", the other is
    # "upgrade that box" — and only the second is something they can act on.
    def unsupported? = unsupported

    def any? = files.present?

    def valid_files = files.select(&:valid?)

    def invalid_files = files.reject(&:valid?)
  end

  # File — one `.voodu/**/*.yml`. Exactly one of `spec` and `error` is set:
  # the box either used the file or explained why it did not.
  File = Struct.new(:path, :spec, :error) do
    def valid? = error.blank?

    def basename = ::File.basename(path.to_s)

    def display_name = spec&.dig("name").presence || basename

    def branches = Array(spec&.dig("on", "push", "branches"))

    def paths = Array(spec&.dig("on", "push", "paths"))

    def apply_file = spec&.dig("apply", "file")

    # The file rendered back as YAML.
    #
    # From the PARSED spec and not from the raw bytes, deliberately: the box
    # never sends the bytes, and asking GitHub for them here would be a second
    # request for something already answered. What the operator sees is what
    # the box understood — which is the more useful of the two when a file is
    # not doing what they expected.
    def to_yaml_text
      return error.to_s if spec.blank?

      spec.to_yaml.delete_prefix("---\n")
    end
  end

  Stats = Struct.new(:files, :bytes, :languages) do
    # Human bytes. The working tree, not the repository — GitHub's own `size`
    # counts git objects with history, which is neither what a deploy
    # downloads nor what a build reads.
    def human_bytes
      ActiveSupport::NumberHelper.number_to_human_size(bytes.to_i)
    end

    # The extensions worth drawing. Named for what is measured: `.h` shared by
    # C and C++ counts once, under `.h`.
    def top_languages(limit = 5) = Array(languages).first(limit)
  end

  def initialize(server:, org:, repo: nil, file: nil, client: nil, github: nil)
    @server = server
    @org = org
    @requested_repo = repo.presence
    @requested_file = file.presence
    @client = client
    @github = github
  end

  attr_reader :server, :org

  # ── connection ─────────────────────────────────────────────────────────

  def integration
    return @integration if defined?(@integration)

    @integration = Integration::Record.active.find_by(org: org, provider: "github")
    backfill_html_url!(@integration)
    @integration
  end

  # backfill_html_url! — rows connected before html_url was captured point
  # the head's GitHub links at the personal-account form of the settings
  # URL, which is wrong for an organization's installation. One lookup, once,
  # best-effort: a GitHub hiccup leaves the fallback in place for this render.
  def backfill_html_url!(record)
    return if record.nil? || record.html_url.present?

    url = github.installation(record.installation_id)["html_url"]
    record.update!(html_url: url) if url.present?
  rescue Integration::Github::Client::Error, Integration::Github::AppJwt::MissingCredentials => e
    Rails.logger.warn("[github] could not backfill html_url for installation #{record.installation_id}: #{e.class}")
  end

  def connected? = integration.present?

  def install_url = GithubSettings.current.install_url

  def app_configured? = GithubSettings.current.configured?

  # ── the cards ──────────────────────────────────────────────────────────

  # repos — every repository the customer authorized, each saying whether it
  # points at THIS server.
  #
  # Authorized-but-not-listed is shown rather than hidden: "I gave you access
  # and it is not here" is the confusing state, and the fix for it is one card
  # away.
  def repos
    @repos ||= begin
      listed = listed_entries

      authorized_repos.map do |row|
        entry = listed[row["full_name"].to_s.downcase]

        Repo.new(
          full_name: row["full_name"].to_s,
          default_branch: row["default_branch"].to_s.presence || "main",
          private: !!row["private"],
          listed: entry.present?,
          trigger_id: entry&.trigger_id
        )
      end.sort_by { |repo| [repo.listed? ? 0 : 1, repo.full_name.downcase] }
    end
  end

  # selected — the card the operator opened, or nothing.
  def selected
    return nil if @requested_repo.nil?

    @selected ||= repos.find { |repo| repo.full_name.casecmp?(@requested_repo) }
  end

  # ── the opened card ────────────────────────────────────────────────────

  # manifests — the box's reading of `selected`, or nil when nothing is open.
  #
  # This is the only method that costs a round trip, and only when a card is
  # open. Every failure below becomes an `unreachable` result with a sentence,
  # never an exception: this renders inside a page the operator is already
  # looking at.
  def manifests
    return nil if selected.nil?

    @manifests ||= fetch_manifests
  end

  # triggers — what the box has authorized, indexed by repository.
  #
  # Read separately from the manifests because they answer different
  # questions: a repository can have a perfectly valid YAML and no trigger,
  # which is exactly the state that leaves an operator wondering why nothing
  # deploys.
  def triggers
    return @triggers if defined?(@triggers)

    @deploy_plane_missing = false
    @triggers = client ? Array(client.deploy_triggers) : []
  rescue Voodu::Client::NotFoundError
    # THE ONE CALL THAT CAN ANSWER THIS. `deploy/triggers` takes no GitHub
    # token and names no repository, so a 404 from it means one thing: the
    # route does not exist on that controller.
    #
    # The manifests call cannot answer it. Its 404 is GitHub's — a repository
    # or ref the token cannot see — and reading that as "no deploy plane" told
    # an operator to upgrade a box that was already upgraded, while the real
    # problem was somewhere else entirely. It did exactly that, to Thadeu, the
    # day it shipped.
    @deploy_plane_missing = true
    @triggers = nil
  rescue Voodu::Client::Error
    @deploy_plane_missing = false
    @triggers = nil
  end

  # deploy_plane_missing? — the controller predates these routes.
  def deploy_plane_missing?
    triggers

    @deploy_plane_missing == true
  end

  # trigger_for — the box's trigger for one repository, or nil.
  #
  # nil and `triggers.nil?` are different answers: no trigger, versus we could
  # not ask. Callers that conflate them tell the operator to create something
  # that already exists.
  def trigger_for(repo_name)
    Array(triggers).find { |trigger| trigger["repo"].to_s.casecmp?(repo_name.to_s) }
  end

  def box_reachable? = !triggers.nil?

  # selected_file — the YAML in the viewer.
  #
  # Defaults to the first file the box could USE. A repository whose first file
  # alphabetically is broken should not open on the broken one — the operator
  # came to see what deploys, and the errors are listed beside it either way.
  def selected_file
    return nil if manifests.nil?

    files = manifests.files

    return nil if files.empty?

    files.find { |file| file.path == @requested_file } ||
      files.find(&:valid?) ||
      files.first
  end

  # ── preflight ──────────────────────────────────────────────────────────

  # preflight — the four questions, asked of the box, for one repository.
  #
  # FOUR SEPARATE ANSWERS AND NOT ONE BOOLEAN, which is the whole point. A
  # firewall, an expired token, a paused trigger and a missing file are four
  # different fixes, and "preflight failed" names none of them.
  #
  # Needs a trigger, because the box's endpoint does: the questions are about
  # an authorization, and there is nothing to ask about before one exists. The
  # panel says "create a trigger first" in that case rather than offering a
  # button that cannot answer.
  # `box_reachable?` is asked FIRST, and not as an optimization. `trigger_for`
  # answers nil both when the box has no trigger and when the box never
  # answered, so reading it alone would tell an operator whose server is down
  # that they have not created a trigger — sending them to create one that
  # already exists.
  def preflight
    return @preflight ||= failed_preflight("#{server.name} did not answer.") unless box_reachable?

    trigger = trigger_for(selected&.full_name)

    return nil if trigger.nil?

    @preflight ||= fetch_preflight(trigger["id"])
  end

  # Preflight — the box's answer, or the reason there is none.
  Preflight = Struct.new(:ok, :repo, :branch, :checks, :error) do
    def ok? = ok

    def failed? = error.present?

    def failing = Array(checks).reject { |check| check.ok }
  end

  # The question each check answers, in the operator's words. The box sends
  # machine names; a screen that printed `manifests_found` would be making the
  # reader translate.
  CHECK_LABELS = {
    "trigger_enabled" => "The trigger is active",
    "container_runtime" => "This box can run containers",
    "github_reachable" => "The box reached GitHub",
    "manifests_found" => "A usable trigger file exists"
  }.freeze

  Check = Struct.new(:name, :ok, :detail) do
    def label = CHECK_LABELS.fetch(name.to_s, name.to_s.humanize)
  end

  # known_scopes — the scopes this box already runs, to suggest in the form.
  #
  # A SUGGESTION AND NOT A CHOICE. `allow_scopes` is what the box checks a
  # deploy's manifests against, and a scope that has nothing running yet is
  # exactly the case somebody is configuring a first deploy for. A closed list
  # would make the common first-time flow impossible.
  def known_scopes
    @known_scopes ||= begin
      payload = client.pods(stats: false)
      rows = Array(payload.is_a?(Hash) ? payload["pods"] : payload)

      rows.filter_map { |pod| pod["scope"].presence }.uniq.sort
    rescue Voodu::Client::Error
      []
    end
  end

  def refresh!
    Rails.cache.delete(repos_cache_key)
    @repos = nil
  end

  private

  def client
    return @client if defined?(@client) && @client

    @client = server && Voodu::Client.new(server)
  end

  def github
    @github ||= Integration::Github::Client.new
  end

  def listed_entries
    return {} if integration.nil?

    integration.repos_for_server(server).index_by { |entry| entry.repo.to_s.downcase }
  end

  # authorized_repos — the GitHub listing, cached.
  #
  # Cached because it changes when a person clicks something on github.com,
  # which is rare, and because this is the render path. The cache holds public
  # metadata — names, default branches, a private flag — and no credential.
  #
  # The TOKEN is deliberately NOT cached. It is minted per call, used once and
  # dropped: a read-only hour-long credential in a cache table is a credential
  # sitting in a database that nothing else about this screen requires.
  def authorized_repos
    return [] if integration.nil?

    Rails.cache.fetch(repos_cache_key, expires_in: REPOS_TTL) do
      github.repositories(integration.installation_id)
    end
  rescue Integration::Github::Client::Error, Integration::Github::AppJwt::MissingCredentials => e
    Rails.logger.warn("[deploys] could not list repositories: #{e.class}")
    []
  end

  def repos_cache_key = "deploys:repos:#{integration&.id}"

  def fetch_preflight(trigger_id)
    token = github.installation_token(integration.installation_id)
    payload = client.deploy_preflight(trigger: trigger_id, token: token)

    Preflight.new(
      !!payload["ok"], payload["repo"], payload["branch"],
      Array(payload["checks"]).map { |row| Check.new(row["name"], !!row["ok"], row["detail"]) },
      nil
    )
  rescue Voodu::Client::TransportError
    failed_preflight("#{server.name} did not answer.")
  rescue Voodu::Client::AuthError
    failed_preflight("This server's token cannot run a preflight — it needs the deploy scope.")
  rescue Voodu::Client::Error => e
    failed_preflight(e.message.presence || "The server refused the request.")
  rescue Integration::Github::Client::Error, Integration::Github::AppJwt::MissingCredentials
    failed_preflight("Could not mint a GitHub token for this installation.")
  end

  def failed_preflight(message)
    Preflight.new(false, selected&.full_name, nil, [], message)
  end

  def fetch_manifests
    return unreachable(nil, unsupported: true) if deploy_plane_missing?

    token = github.installation_token(integration.installation_id)

    payload = client.deploy_manifests(
      token: token, repo: selected.full_name, ref: selected.default_branch
    )

    build_manifests(payload)
  rescue Voodu::Client::TransportError
    unreachable("#{server.name} did not answer. The deploy plane needs this box reachable from here.")
  rescue Voodu::Client::AuthError
    unreachable("This server's token cannot read deploy config — it needs the deploy scope.")
  rescue Voodu::Client::Error => e
    unreachable(e.message.presence || "The server refused the request.")
  rescue Integration::Github::Client::Error, Integration::Github::AppJwt::MissingCredentials
    unreachable("Could not mint a GitHub token for this installation. Reconnect GitHub and try again.")
  end

  def build_manifests(payload)
    stats = payload["stats"] || {}

    Manifests.new(
      repo: payload["repo"],
      ref: payload["ref"],
      commit: payload["commit"],
      truncated: !!payload["truncated"],
      unreachable: false,
      files: Array(payload["files"]).map do |row|
        File.new(path: row["path"], spec: row["spec"], error: row["error"])
      end,
      stats: Stats.new(
        files: stats["files"].to_i,
        bytes: stats["bytes"].to_i,
        languages: Array(stats["languages"])
      )
    )
  end

  def unreachable(message, unsupported: false)
    Manifests.new(
      repo: selected&.full_name, files: [], unreachable: true, unsupported: unsupported,
      error: message, stats: Stats.new(files: 0, bytes: 0, languages: [])
    )
  end
end
