# frozen_string_literal: true

# One deployment as a table row.
#
# Its own component because it renders in two places: the Deployments table,
# and the "Produced" list on a delivery — one webhook can fan out to several
# deployments, and that list is the other half of the link. Two copies of a row
# are two rows that drift.
class Components::Deploys::DeploymentRow < Components::Base
  def initialize(deployment:)
    @deployment = deployment
  end

  def view_template
    deployment = @deployment

    a(href: deploys_deployment_path(id: deployment.id),
      class: "flex flex-col vmd:flex-row vmd:items-center gap-1 vmd:gap-3 px-3 py-2.5 " \
             "no-underline border-b border-voodu-border last:border-b-0 hover:bg-voodu-hover") do
      sender_cell(deployment)
      sha_cell(deployment)
      message_cell(deployment)
      repo_cell(deployment)
      took_cell(deployment)
      status_cell(deployment)
      when_cell(deployment)
    end
  end

  private

  # Who pushed, before the SHA: in a list you scan for "one of mine" first and
  # read the commit second.
  #
  # A `div` AND NOT A `span`. The Sender renders a div, and `<span><div>` is
  # invalid nesting: the parser closes the span early and every cell after it
  # spills out of the flex row — the row stops being a row. It looked like a
  # layout bug and it was a markup one.
  #
  # THE SLOT IS ALWAYS DRAWN, even when nobody is in it. The Sender component
  # renders nothing for a deploy with no sender — right, because a blank circle
  # is a person who does not exist — but a cell that disappears takes its
  # column width with it, and every header to its right stops lining up with
  # the rows below. That is exactly what happened.
  def sender_cell(deployment)
    div(class: "hidden vmd:block w-5 shrink-0") do
      render Components::Deploys::Sender.new(
        login: deployment.sender, avatar: deployment.sender_avatar, url: deployment.sender_url,
        # The row is already a link — see Sender for why a second one here
        # silently breaks the flex row.
        linked: false
      )
    end
  end

  def sha_cell(deployment)
    span(class: "vmd:w-20 shrink-0 font-voodu-mono text-[12px] text-voodu-text") do
      deployment.short_sha
    end
  end

  def message_cell(deployment)
    span(class: "flex-1 min-w-0 text-[12.5px] text-voodu-text-2 truncate") do
      deployment.commit_message.presence || "—"
    end
  end

  def repo_cell(deployment)
    span(class: "hidden vmd:block w-40 shrink-0 font-voodu-mono text-[11px] text-voodu-muted truncate") do
      deployment.repo
    end
  end

  def took_cell(deployment)
    span(class: "hidden vmd:block w-16 shrink-0 text-right font-voodu-mono text-[11px] text-voodu-muted") do
      duration(deployment)
    end
  end

  def status_cell(deployment)
    span(class: "vmd:w-24 shrink-0") do
      render Components::Deployments::StatusBadge.new(status: deployment.status)
    end
  end

  def when_cell(deployment)
    span(class: "vmd:w-24 shrink-0 vmd:text-right text-[11px] text-voodu-muted",
      title: deployment.created_at.to_fs(:long)) do
      "#{ActionController::Base.helpers.time_ago_in_words(deployment.created_at)} ago"
    end
  end

  def duration(deployment)
    return "—" if deployment.started_at.nil? || deployment.finished_at.nil?

    seconds = (deployment.finished_at - deployment.started_at).round

    (seconds < 60) ? "#{seconds}s" : "#{seconds / 60}m#{seconds % 60}s"
  end
end
