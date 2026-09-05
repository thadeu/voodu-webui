# frozen_string_literal: true

# Integration::Record — one org's connection to a source provider.
#
# Namespaced under `Integration::` so everything orbiting this — the repository
# value object, the preflight, the webhook handling — lives together instead of
# scattered across the root of models/.
#
# ONE ROW PER ORG, not per repository. That is what makes "connected and
# nothing configured yet" representable, which is exactly the state in the
# instant after the GitHub callback.
#
# For GitHub the connection is an `installation_id`, and it is a NUMBER that
# opens nothing on its own: minting a token from it needs the App's private
# key, which lives on this installation and never travels. That is why this
# table is not a secret store and does not need to be.
class Integration::Record < ApplicationRecord
  self.table_name = "integrations"

  # PROVIDERS is the single source for validation, the form and the docs. A new
  # one is an entry here — not a migration, and not a branch in five places.
  PROVIDERS = %w[github].freeze

  STATUSES = %w[active revoked].freeze

  belongs_to :org

  # account_login is display: whose GitHub account the App is installed on.
  # `repos` is read through the reader below, which hands back value objects.
  store_accessor :config, :account_login

  # The GitHub word for `external_id`, where it reads better. The column stays
  # provider-agnostic because GitLab calls this something else.
  alias_attribute :installation_id, :external_id

  validates :provider, presence: true, inclusion: {in: PROVIDERS}
  validates :status, presence: true, inclusion: {in: STATUSES}
  validates :external_id, presence: true

  # One row per (org, provider, external_id) — NOT per (org, provider).
  #
  # An org may connect SEVERAL GitHub accounts: `acme-corp` feeding one server
  # and `acme-labs` feeding another. Those are two installations, and refusing
  # the second would be a limit nobody could explain. What this forbids is the
  # same installation recorded twice for one org, which is the real duplicate.
  validates :external_id, uniqueness: {scope: [:org_id, :provider]}

  scope :active, -> { where(status: "active") }

  # Target — one place a delivery should land: a server, and the trigger handle
  # on it. Carries the integration so the caller can check the server belongs
  # to the org that listed it.
  Target = Struct.new(:integration, :repo, :server, :trigger_id)

  # for_delivery — the webhook's only lookup.
  #
  # It arrives with no session, no org and no user: just an installation id and
  # a repository name. Starting from the installation is what makes the tenant
  # scoping STRUCTURAL — a delivery never had a way to name an org, so it
  # cannot reach one that did not list it.
  #
  # EVERY matching row, not the first. Two things make that necessary and
  # `find_by` wrong:
  #
  #   - one repository may deploy to two servers, a staging box and a
  #     production one, and both should fire
  #   - the same GitHub account can be connected by two of the customer's orgs,
  #     which produces two rows with the SAME external_id — `find_by` would
  #     pick one arbitrarily and silently drop the other org's deploys
  #
  # Each target's server is resolved and checked against the listing row's org
  # here, so a stale or foreign server_id in a blob cannot become a deploy.
  def self.for_delivery(provider, external_id, repo)
    rows = active.where(provider: provider, external_id: external_id.to_s)

    rows.flat_map { |integration| integration.targets_for(repo) }
  end

  # targets_for — this row's deliverable entries for a repository.
  def targets_for(repo_name)
    live = org.servers.index_by(&:id)

    repos.filter_map do |entry|
      next unless entry.matches?(repo_name)

      server = live[entry.server_id]

      # A server that is gone, or that belongs to another org, is not a target.
      # The blob has no foreign key, so this read is the only thing standing
      # between a stale id and a deploy.
      next if server.nil?

      Target.new(self, entry.repo, server, entry.trigger_id)
    end
  end

  def github? = provider == "github"

  def active? = status == "active"

  # revoke! rather than destroy: an installation the customer removed on
  # GitHub's side is history worth keeping, and a row that vanishes takes the
  # answer to "why did deploys stop" with it.
  #
  # The repository list stays. Reconnecting should not mean rebuilding it.
  def revoke! = update!(status: "revoked")

  # repos — the configured repositories, as value objects.
  #
  # Incomplete entries are DROPPED on read rather than raising. This list is a
  # blob without database constraints, so a half-written entry is reachable —
  # and a screen that 500s because one row is malformed is worse than a screen
  # missing one row.
  def repos
    Array(config["repos"]).map { |entry| Integration::Repo.from(entry) }.select(&:valid?)
  end

  # deployable_repos — the entries whose server still exists and belongs to
  # this org.
  #
  # The blob carries no foreign key, so a deleted server leaves an orphan. The
  # READ is what protects: cleanup on destroy can fail, and this cannot be
  # skipped by anything that asks the question.
  def deployable_repos
    live = org.servers.pluck(:id).to_set

    repos.select { |entry| live.include?(entry.server_id) }
  end

  # repos_for_server — which repositories deploy to one server.
  #
  # This is where "server A uses GitHub, server B does not" lives, and it is a
  # LIST rather than a flag: a server with no entries does not use GitHub, and
  # nothing has to be switched off for that to be true. The GitHub installation
  # cannot be per-server — GitHub allows one installation of an App per account
  # — so the per-server decision is which repositories point at it.
  def repos_for_server(server)
    server_id = server.is_a?(::Server) ? server.id : server.to_i

    repos.select { |entry| entry.server_id == server_id }
  end

  def repo_for(repo_name)
    repos.find { |entry| entry.matches?(repo_name) }
  end

  # add_repo! / remove_repo! — the only writers of the list.
  #
  # `with_lock` and not optimistic locking: two people connecting two
  # repositories at once do a read-modify-write over the same blob, and the
  # loser of that race should WAIT rather than be told their click failed.
  # Optimistic locking would turn a collision into an error in the face of
  # whoever happened to be second.
  def add_repo!(repo:, server_id:, trigger_id:)
    entry = Integration::Repo.new(repo: repo, server_id: server_id, trigger_id: trigger_id)

    raise ArgumentError, "incomplete repo entry" unless entry.valid?

    with_lock do
      kept = repos.reject { |e| e.matches?(entry.repo) && e.server_id == entry.server_id }

      write_repos(kept + [entry])
    end

    entry
  end

  def remove_repo!(repo:, server_id: nil)
    with_lock do
      kept = repos.reject do |entry|
        entry.matches?(repo) && (server_id.nil? || entry.server_id == server_id.to_i)
      end

      write_repos(kept)
    end
  end

  private

  def write_repos(entries)
    # config is reassigned rather than mutated: ActiveRecord tracks the
    # attribute, and mutating the hash in place leaves it thinking nothing
    # changed — the write silently does nothing.
    self.config = config.merge("repos" => entries.map(&:to_h))

    save!
  end
end
