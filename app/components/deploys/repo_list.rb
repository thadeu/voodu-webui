# frozen_string_literal: true

# The repository list: the sub-sidebar of the Repositories tab.
#
# A LIST AND NOT THE CARD GRID IT REPLACED. The grid read well with six
# repositories and badly with forty — and forty is the normal case, because the
# list is the whole GitHub installation while the screen is one server. A list
# scans; a grid of mostly-identical cards does not.
#
# Repositories that deploy here come first and are marked. The ones that do not
# are still shown: "I authorised this on GitHub and it is not here" is the
# confusing state, and the fix is one click away.
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
          @repos.each { |repo| item(repo) }
        end
      end
    end
  end

  private

  # list_head, not `header` — that is a Phlex HTML tag method.
  def list_head
    div(class: "shrink-0 flex items-center gap-2 px-3 h-9 border-b border-voodu-border") do
      span(class: "text-[11px] font-semibold uppercase tracking-wider text-voodu-text-2") do
        "Repositories"
      end

      div(class: "flex-1")

      span(class: "font-voodu-mono text-[11px] text-voodu-muted") { @repos.size.to_s }
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

        render Icon::LockClosedOutline.new(class: "w-3 h-3 shrink-0 text-voodu-muted-2") if repo.private?
      end

      span(class: "text-[10.5px] text-voodu-muted truncate pl-3") { repo.owner }
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
