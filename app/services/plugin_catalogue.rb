# frozen_string_literal: true

# PluginCatalogue — the plugins that exist, whether or not this server has them.
#
# Without it the screen could only ever show what was already installed, which
# makes it an inventory rather than a marketplace: an operator who has never
# installed anything sees an empty page and no way to learn that voodu-postgres
# exists. Discovery is the point.
#
# Hard-coded on purpose. The alternative is asking GitHub for an org's
# repositories on every page load, which means an outbound call from a
# dashboard that otherwise talks only to the operator's own boxes, plus rate
# limits and a token for private repos. A list that changes a few times a year
# does not justify that. When it grows past hand-editing, it becomes a JSON
# file the release publishes — not a live API call.
#
# Only what can actually be installed today. An entry for something announced
# but unreleased is a card with no working button, and a promise the page
# cannot keep — better absent than present and inert.
class PluginCatalogue
  # An entry IS its repository. The display name is the repository's own name,
  # not the plugin name inside it — thadeu/voodu-hep3 shows as "voodu-hep3".
  #
  # Those two differ (that repo installs a plugin called "hep3") and translating
  # between them was a table to keep in sync and a card that renamed itself
  # halfway through an install. Showing what we were given is idempotent: the
  # same repository always produces the same card.
  Entry = Struct.new(:source, :description) do
    def name = source.split("/").last.to_s

    def homepage = "https://github.com/#{source}"
  end

  ENTRIES = [
    Entry.new("thadeu/voodu-caddy",
      "Ingress backed by the Caddy Admin API. ACME, on-demand wildcard TLS."),
    Entry.new("thadeu/voodu-postgres",
      "Postgres clusters: streaming replication, WAL archive, backup and restore with PITR."),
    Entry.new("thadeu/voodu-redis",
      "Redis with replication, AOF persistence and Sentinel-based auto-failover."),
    Entry.new("thadeu/voodu-traffik",
      "Layer 4 load balancer with connection-aware draining, for zero-drop rolling restarts."),
    Entry.new("thadeu/voodu-hep3",
      "HEP3 capture: SIP signalling and RTP quality, stored and searchable.")
    # Entry.new("thadeu/voodu-mysql",
    #   "MySQL with replication and managed backups.")
  ].freeze

  def self.all = ENTRIES

  # Everything the catalogue knows that this server does not already have — or
  # is not in the middle of getting.
  #
  # Two handles, because neither sees every case:
  #
  #   name      what the row calls itself. Since a card is named for its
  #             repository, this catches an install still running — the
  #             controller derives the same name from the same source.
  #   homepage  where an INSTALLED plugin says it came from. Needed because a
  #             manifest names the plugin, not the repository: thadeu/
  #             voodu-traffik installs something called "traffik", and the name
  #             alone would offer an install for a plugin already there.
  #
  # A third lookup on the in-flight `source` was here and came out: with cards
  # named after repositories it never decided anything the name had not already
  # decided, and a branch no test can distinguish is a claim nobody can check.
  def self.available(rows)
    names = rows.map { |p| p.name.to_s.downcase }.to_set
    repos = rows.filter_map { |p| repo_path(p.homepage) }.to_set

    ENTRIES.reject { |e| names.include?(e.name) || repos.include?(repo_path(e.homepage)) }
  end

  # "https://github.com/thadeu/voodu-redis" → "thadeu/voodu-redis". Nil for
  # anything without that shape, so a locally-installed plugin never collides
  # with a catalogue entry by accident.
  def self.repo_path(ref)
    path = ref.to_s.strip
    return nil if path.empty? || path.start_with?("/")

    path = path.sub(%r{\Ahttps?://(www\.)?}, "").sub(/\Agit@/, "").tr(":", "/")
    path = path.delete_suffix(".git").chomp("/")

    parts = path.split("/").reject(&:empty?)
    return nil if parts.size < 2

    parts.last(2).join("/").downcase
  end
end
