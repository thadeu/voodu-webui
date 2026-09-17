# frozen_string_literal: true

# The repository list: the sub-sidebar of the Repositories tab.
#
# A LIST AND NOT THE CARD GRID IT REPLACED. The grid read well with six
# repositories and badly with forty — and forty is the normal case, because the
# list is the whole GitHub installation while the screen is one server. A list
# scans; a grid of mostly-identical cards does not.
#
# The list is the repositories that deploy to THIS server. The rest of the
# installation — authorized on GitHub, pointed at no trigger here — sits
# under a folded "Available from GitHub" section below it, because the
# installation is one per account and the screen is one server: a database
# box listed every app repository as if something had been set up for it,
# and nothing had. Folded rather than hidden, since "I authorized this on
# GitHub and it is not here" is still the confusing state, and the fix is
# one click away: open the repository and create its trigger. It unfolds
# by itself when one of its repositories is the one open, or when nothing
# deploys here yet and it is the only thing there is to show.
class Components::Deploys::RepoList < Components::Base
  def initialize(repos:, selected: nil)
    @repos = repos
    @selected = selected
  end

  def view_template
    div(class: "vmd:w-64 shrink-0 flex flex-col border border-voodu-border bg-voodu-surface " \
               "vmd:max-h-[calc(100vh-220px)]") do
      list_head

      if @repos.empty?
        empty
      else
        div(class: "flex-1 min-h-0 overflow-y-auto") do
          listed.each { |repo| item(repo) }
          nothing_listed if listed.empty?
          available if unlisted.any?
        end
      end
    end
  end

  private

  def listed = @listed ||= @repos.select(&:listed?)

  def unlisted = @unlisted ||= @repos.reject(&:listed?)

  # list_head, not `header` — that is a Phlex HTML tag method.
  def list_head
    div(class: "shrink-0 flex items-center gap-2 px-3 h-9 border-b border-voodu-border") do
      span(class: "text-[11px] font-semibold uppercase tracking-wider text-voodu-text-2") do
        "Repositories"
      end

      div(class: "flex-1")

      span(class: "font-voodu-mono text-[11px] text-voodu-muted") { listed.size.to_s }
    end
  end

  def nothing_listed
    div(class: "px-3 py-3 text-[11.5px] text-voodu-muted leading-relaxed") do
      "Nothing deploys to this server yet."
    end
  end

  def available
    open = listed.empty? || unlisted.any? { |repo| @selected&.casecmp?(repo.full_name) }

    details(open: open, class: "group/available border-t border-voodu-border") do
      summary(class: "flex items-center gap-2 px-3 h-9 cursor-pointer select-none text-voodu-muted hover:text-voodu-text list-none [&::-webkit-details-marker]:hidden") do
        render Icon::ChevronRightOutline.new(class: "w-3 h-3 shrink-0 transition-transform group-open/available:rotate-90")
        span(class: "text-[11px] font-semibold uppercase tracking-wider") { "Available from GitHub" }
        div(class: "flex-1")
        span(class: "font-voodu-mono text-[11px]") { unlisted.size.to_s }
      end

      div(class: "px-3 pb-2 text-[11px] text-voodu-muted leading-relaxed") do
        "Authorized on the GitHub App, not deploying here. Open one to connect it."
      end

      unlisted.each { |repo| item(repo) }
    end
  end

  def item(repo)
    active = @selected&.casecmp?(repo.full_name)

    a(href: deploys_repositories_path(repo: repo.full_name),
      title: repo.full_name, class: item_class(active)) do
      div(class: "flex items-center gap-1.5 min-w-0") do
        # A dot rather than a badge: at list width a word competes with the
        # name it qualifies, and the name is what somebody is scanning for.
        span(class: "shrink-0 w-1.5 h-1.5 rounded-full #{repo.listed? ? "bg-voodu-accent" : "bg-voodu-border-2"}",
          title: repo.listed? ? "Deploys here" : "Not connected")

        span(class: "text-[12.5px] truncate") { repo.name }

        private_badge if repo.private?
      end

      span(class: "text-[10.5px] text-voodu-muted truncate pl-3") { repo.owner }
    end
  end

  # A lock with no label is a lock somebody has to guess at; the tooltip
  # names it on hover and the aria-label names it for everyone else.
  def private_badge
    span(class: "relative group/private inline-flex shrink-0", "aria-label": "Private repository") do
      render Icon::LockClosedOutline.new(class: "w-3 h-3 text-voodu-muted-2")
      render Components::UI::Tooltip.new(label: "Private repository", group: "private")
    end
  end

  def item_class(active)
    base = "flex flex-col gap-0.5 px-3 py-2 border-l-2 no-underline transition-colors "

    base + if active
      "border-l-voodu-accent bg-voodu-accent-dim text-voodu-text"
    else
      "border-l-transparent text-voodu-text-2 hover:bg-voodu-hover"
    end
  end

  def empty
    div(class: "px-3 py-6 text-center text-[12px] text-voodu-muted") do
      "No repositories yet"
    end
  end
end
