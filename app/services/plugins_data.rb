# frozen_string_literal: true

# PluginsData — what the Plugins screen renders, for one server.
#
# Nothing here is persisted. A plugin lives on the controller's disk, so the
# box is the only source of truth and a row in our database could only ever
# drift from it. What we DO keep is a short-lived cache, because the list
# changes rarely and a page refresh should not cost a round trip across
# whatever network sits between here and the server.
#
# The cache is deliberately shallow. It is invalidated the moment this
# installation changes anything (install or uninstall), so the operator never
# watches a stale card after their own click — only somebody else's change, or
# a plugin that finished installing, waits out the TTL. And the polling frame
# makes that wait invisible in the case that matters: an install in flight.
class PluginsData
  # Short enough that an install finishing feels immediate on the next poll,
  # long enough that a refresh-happy operator is not hammering the box.
  TTL = 20.seconds

  # A card, flattened out of the controller's payload so the view never digs
  # through a hash. `state` is one of installed / installing / failed.
  Plugin = Struct.new(
    :name, :version, :description, :homepage, :aliases, :commands,
    :state, :source, :error
  ) do
    def installed? = state == "installed"

    # In the catalogue and not on this server.
    def available? = state == "available"

    def installing? = state == "installing"

    def failed? = state == "failed"

    # A repository we can link to. Blank for a plugin installed from a path on
    # the box, which is a real case and must not render a dead link.
    def homepage_url
      url = homepage.to_s.strip

      url.start_with?("http://", "https://") ? url : nil
    end

    def version_label = version.presence ? "v#{version}" : nil
  end

  PER_PAGE = 25

  SORTS = {"name_asc" => "Name A–Z", "name_desc" => "Name Z–A"}.freeze
  DEFAULT_SORT = "name_asc"

  def initialize(server:, client: nil, page: 1, sort: nil)
    @server = server
    @client = client
    @page = page.to_i.clamp(1, Float::INFINITY).to_i
    @sort = SORTS.key?(sort.to_s) ? sort.to_s : DEFAULT_SORT
  end

  attr_reader :sort

  # Installed first, then what the catalogue offers and this server does not
  # have. Order within each group follows the sort; the groups themselves do
  # not interleave, because "what I have" and "what I could have" are different
  # questions and mixing them makes the first one hard to answer.
  def listing
    return @listing if defined?(@listing)

    @listing = sorted(plugins) + sorted(available_entries)
  end

  # The slice this page shows. Paging happens here rather than on the wire
  # because the controller answers with everything it has — a box's plugin
  # count is small, and asking it for a window would trade a real round trip
  # for an imagined saving.
  def page_of_plugins
    listing[offset, PER_PAGE] || []
  end

  def per_page = PER_PAGE

  def total = listing.size

  def installed_count = plugins.size

  def available_count = available_entries.size

  def total_pages = [(total.to_f / PER_PAGE).ceil, 1].max

  # Clamped, so a bookmarked ?page=9 on a server that has since lost plugins
  # lands on the last real page instead of on nothing.
  def page = @page.clamp(1, total_pages)

  def paginated? = total_pages > 1

  # The list, from cache when it is warm.
  #
  # A transport failure is not an empty list: an unreachable box would
  # otherwise render as "no plugins installed", which reads as a fact and is a
  # lie. `error` carries the reason and the view says so instead.
  def plugins
    return @plugins if defined?(@plugins)

    @plugins = fetch_cached
  end

  def error
    plugins

    @error
  end

  # True when the server answered 404 — this controller predates the plugin
  # endpoints. Worth separating from a transport failure because the two send
  # the operator to completely different places: one is "check the network",
  # the other is "upgrade that box", and only one of them is their fault.
  def unsupported?
    plugins

    @unsupported == true
  end

  def reachable? = error.nil?

  def any? = plugins.any?

  # Called after this installation changes something, so the operator's own
  # action is reflected on the very next render rather than up to TTL later.
  def self.expire!(server)
    Rails.cache.delete(cache_key(server))
  end

  def self.cache_key(server)
    "plugins/v1/#{server.id}"
  end

  private

  def sorted(rows)
    ordered = rows.sort_by { |r| r.name.to_s.downcase }

    (@sort == "name_desc") ? ordered.reverse : ordered
  end

  # Only when the server actually answered. Offering installs against a box we
  # could not reach would be inviting a click that cannot work.
  def available_entries
    return [] unless reachable?

    @available_entries ||= PluginCatalogue.available(plugins).map { |entry| catalogue_plugin(entry) }
  end

  def catalogue_plugin(entry)
    Plugin.new(
      name: entry.name, version: "", description: entry.description,
      homepage: entry.homepage, aliases: [], commands: [],
      state: "available",
      source: entry.source, error: ""
    )
  end

  def offset = (page - 1) * PER_PAGE

  def fetch_cached
    cached = Rails.cache.read(self.class.cache_key(@server))
    return build(cached) if cached

    payload = fetch_remote
    return [] if payload.nil?

    Rails.cache.write(self.class.cache_key(@server), payload, expires_in: TTL)

    build(payload)
  end

  def fetch_remote
    @error = nil
    @unsupported = false

    client.plugins
  rescue Voodu::Client::NotFoundError => e
    @unsupported = true
    @error = e.message

    nil
  rescue Voodu::Client::Error => e
    @error = e.message

    nil
  end

  def build(payload)
    rows = Array(payload.is_a?(Hash) ? payload["plugins"] : payload)

    rows.filter_map { |row| plugin_from(row) }.sort_by { |p| p.name.to_s.downcase }
  end

  def plugin_from(row)
    return nil unless row.is_a?(Hash)

    name = row["name"].to_s
    return nil if name.empty?

    Plugin.new(
      name: name,
      version: row["version"].to_s,
      description: row["description"].to_s,
      homepage: row["homepage"].to_s,
      aliases: Array(row["aliases"]).map(&:to_s),
      commands: Array(row["commands"]).map(&:to_s),
      state: row["state"].presence || "installed",
      source: row["source"].to_s,
      error: row["error"].to_s
    )
  end

  def client
    @client ||= Voodu::Client.new(@server)
  end
end
