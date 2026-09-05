# frozen_string_literal: true

# The Repositories tab: which repositories deploy to this server.
#
# READ-ONLY except for connecting and disconnecting, and the absent save button
# is the decision. Our GitHub App holds `contents: read` and nothing more, so
# the way to change what a trigger DOES is to commit to the repository, where
# the change is reviewed like any other. The screen says so rather than leaving
# somebody hunting.
class Views::Deploys::Repositories < Views::Deploys::Shell
  private

  def tab = :repositories

  def subtitle
    "Push to a connected repository and #{@current_server&.name} applies it. " \
      "The trigger lives in the repository, so changing it is a commit."
  end

  def content
    if @data.nil?
      render Components::UI::NoServerState.new
    elsif !@data.connected?
      connect_state
    else
      browser
    end
  end

  # The list beside the panel. Stacks below the breakpoint, where a 256px
  # sidebar next to content is two unusable columns.
  def browser
    div(class: "flex flex-col vmd:flex-row gap-3 vmd:gap-4 items-stretch") do
      render Components::Deploys::RepoList.new(repos: @data.repos, selected: @data.selected&.full_name)

      div(class: "flex-1 min-w-0") do
        @data.selected ? panel : nothing_selected
      end
    end
  end

  def panel
    div(class: "border border-voodu-border bg-voodu-surface p-3.5") do
      render Components::Deploys::ManifestPanel.new(data: @data)
    end
  end

  # Not an error and not an empty state — the operator has simply not picked
  # one yet, and the list beside this is the thing to do next.
  def nothing_selected
    div(class: "h-full flex items-center justify-center border border-voodu-border " \
               "bg-voodu-surface px-3.5 py-10 text-center") do
      p(class: "m-0 text-[12.5px] text-voodu-muted") do
        "Pick a repository to see its trigger files."
      end
    end
  end

  # Two reasons there is nothing to show, and they are not the same fix: the
  # installation has no App configured (ours), or this org has not connected
  # one (theirs).
  def connect_state
    render Components::UI::SectionCard.new(title: "Connect GitHub") do
      div(class: "p-3.5 flex flex-col gap-3") do
        if @data.app_configured?
          p(class: "m-0 text-[12.5px] text-voodu-text-2") do
            plain "Authorize our app on the repositories you want to deploy from. "
            plain "You pick which ones on GitHub's own screen — we cannot widen it afterwards."
          end

          render Components::UI::Button.new(
            tag: :a, href: connect_github_path, variant: :primary, size: :sm, class: "self-start"
          ) { span { "Connect GitHub" } }
        else
          p(class: "m-0 text-[12.5px] text-voodu-text-2") do
            "This installation has no GitHub App configured, so there is nothing to connect to yet."
          end
          p(class: "m-0 text-[12px] text-voodu-muted") do
            "An operator sets it up once for the whole installation."
          end
        end
      end
    end
  end
end
