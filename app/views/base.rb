# frozen_string_literal: true

class Views::Base < Components::Base
  # The `Views::Base` is an abstract class for all your views.

  # By default, it inherits from `Components::Base`, but you
  # can change that to `Phlex::HTML` if you want to keep views and
  # components independent.

  # More caching options at https://www.phlex.fun/components/caching
  def cache_store = Rails.cache

  # overview_crumbs — standard breadcrumb trail rooted at the current
  # server's Overview, for the Dashboard `breadcrumb:` kwarg. Pass the
  # trail AFTER Overview as { label:, href: } hashes (last = current,
  # rendered as plain text). Returns [] when there's no server so the
  # NoServerState pages render no crumb. Management pages (no server)
  # build their crumbs inline instead.
  def overview_crumbs(*trail)
    return [] if @current_server.nil?

    key = @current_server.key

    [{label: "Overview", href: server_root_path(server_key: key)}, *trail]
  end
end
