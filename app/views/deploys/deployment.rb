# frozen_string_literal: true

# One deployment: what happened, and what it put on the box.
#
# THE RESOURCE LIST IS THE POINT OF THE SCREEN. "Succeeded" is a status; "these
# three containers are running this commit" is the thing that turns the CPU
# chart next door into an answer. Every resource links to the pods running it,
# and every pod links back here.
#
# Lives inside the Deploys shell rather than on a route of its own: it is the
# Deployments tab with one row opened, not a different place.
class Views::Deploys::Deployment < Views::Deploys::Shell
  def initialize(current_path:, servers: [], current_server: nil, data: nil, **)
    super
    @deployment = data&.deployment
  end

  private

  def tab = :deployments

  def subtitle = nil

  def breadcrumb
    [
      {label: "Deploys", href: deploys_repositories_path},
      {label: "Deployments", href: deploys_deployments_path},
      {label: @deployment.short_sha}
    ]
  end

  def content
    div(class: "flex flex-col gap-4") do
      back_link
      deployment_head
      failure_card if @deployment.status == "failed"
      skipped_card if @deployment.status == "skipped"
      held_card if @deployment.dispatchable?
      facts_card
      resources_card
      log_card if @deployment.log.present?
    end
  end

  # The way back to the table this replaced. A browser Back would work, but a
  # reader who arrived from a link elsewhere — a pod's "deployed from" strip —
  # has nowhere to go back TO.
  def back_link
    a(href: deploys_deployments_path,
      class: "self-start inline-flex items-center gap-1.5 text-[12px] text-voodu-link no-underline") do
      render Icon::ArrowLeftOutline.new(class: "w-3.5 h-3.5")
      span { "All deployments" }
    end
  end

  # deployment_head, not `header` — that is a Phlex HTML tag method.
  def deployment_head
    div(class: "flex flex-col vmd:flex-row vmd:items-start gap-2") do
      div(class: "flex flex-col gap-1.5 basis-full vmd:basis-auto vmd:flex-1 min-w-0") do
        div(class: "flex flex-wrap items-center gap-2") do
          render Components::Deploys::Sender.new(
            login: @deployment.sender, avatar: @deployment.sender_avatar,
            url: @deployment.sender_url, size: :sm
          )

          render Components::Deployments::StatusBadge.new(status: @deployment.status)

          h1(class: "text-[17px] font-semibold text-voodu-text font-voodu-mono") do
            @deployment.short_sha
          end
        end

        p(class: "m-0 text-[12.5px] text-voodu-text-2 break-words") do
          @deployment.commit_message.presence || @deployment.repo
        end
      end

      commit_link
    end
  end

  # The one thing this screen cannot answer is "what actually changed in the
  # code", and there are two answers a click away: the commit, and the DIFF
  # against what the box had before.
  #
  # Both URLs come from the payload rather than being built from repo and SHA.
  # GitHub hands them over, and a URL we assemble is a URL that breaks the day
  # they change a path — silently, into a 404 the operator reads as "the commit
  # is gone".
  def commit_link
    div(class: "flex items-center gap-2 shrink-0") do
      external(@deployment.compare_url, :ArrowsRightLeftOutline, "Changes")
      external(commit_href, :ArrowTopRightOnSquareOutline, "Commit")
    end
  end

  # The payload's URL when we have it; assembled only as a fallback, for a
  # deployment that predates us keeping it.
  def commit_href
    return @deployment.commit_url if @deployment.commit_url.present?
    return nil if @deployment.sha.blank?

    "https://github.com/#{@deployment.repo}/commit/#{@deployment.sha}"
  end

  def external(href, icon, label)
    return if href.blank?

    render Components::UI::Button.new(
      tag: :a, href: href, target: "_blank", rel: "noopener noreferrer",
      variant: :ghost, size: :sm, data: {turbo_prefetch: "false"}
    ) do
      render Icon.const_get(icon).new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { label }
    end
  end

  def failure_card
    render Components::UI::Callout.new(tone: :danger, title: "This deploy did not complete") do
      span(class: "text-[12.5px] text-voodu-text-2 break-words") { @deployment.error.to_s }
    end
  end

  # Not red. A push that matched no trigger file is the normal outcome of a
  # README change on a repository that watches `app/**`, and coloring it like
  # a failure trains people to ignore failures.
  def skipped_card
    # NEUTRAL, never red. A push that matched no trigger file — a README
    # commit on a repository that watches `app/**` — is the normal outcome, and
    # coloring it like a failure trains operators to ignore failures.
    render Components::UI::Callout.new(tone: :neutral, title: "Nothing was deployed") do
      span(class: "text-[12.5px] text-voodu-text-2") do
        @deployment.skipped_reason.presence || "This push did not match any trigger."
      end
    end
  end

  # The push arrived and a trigger file said `deploy: manual`. Amber, the same
  # tone as "Not deploying here yet": something is waiting on a person, and
  # nothing is wrong. The button is the only one on the screen that changes
  # what runs, so it is confirmed and it names the commit.
  def held_card
    files = Array(@deployment.held).to_sentence
    title = if @deployment.rerun?
      "Deploy this commit again"
    elsif @deployment.held?
      "Waiting for you to deploy"
    else
      "Some of this push is still waiting"
    end

    render Components::UI::Callout.new(tone: :warning, title: title) do
      div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2") do
        span(class: "flex-1 min-w-0 text-[12.5px] text-voodu-text-2") do
          plain "#{files} #{Array(@deployment.held).one? ? "is" : "are"} marked "
          code(class: "font-voodu-mono text-[11.5px]") { "deploy: manual" }
          plain ". Nothing applies until you press play — this commit, not the newest one."
          plain " A re-run is recorded as a new deployment, so this one keeps its result." if @deployment.rerun?
        end

        dispatch_form
      end
    end
  end

  def dispatch_form
    form(action: dispatch_deploys_deployment_path(id: @deployment.id), method: "post", class: "shrink-0") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

      render Components::UI::Button.new(
        tag: :button, type: :submit, variant: :primary, size: :sm,
        data: {turbo_confirm: Components::Deploys::DispatchPrompt.for(@deployment)}
      ) do
        render Icon::PlayOutline.new(class: "w-3.5 h-3.5")
        span { "Deploy #{@deployment.short_sha}" }
      end
    end
  end

  def facts_card
    render Components::UI::SectionCard.new(title: "Details") do
      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-x-6") do
        fact("Repository", @deployment.repo)
        fact(@deployment.tag? ? "Tag" : "Branch", @deployment.branch.presence)
        fact("Pushed by", @deployment.sender.presence || @deployment.pusher.presence)
        fact("Files changed", @deployment.changed_files&.to_s)
        fact("Started", timestamp(@deployment.started_at))
        fact("Finished", timestamp(@deployment.finished_at))
        fact("Took", duration)
        fact("Trigger files", Array(@deployment.applied).join(", ").presence)
        fact("Held", Array(@deployment.held).join(", ").presence)
        fact("Re-run of", @deployment.parent&.short_sha && "deployment ##{@deployment.parent_id}")
        fact("Dispatched by", @deployment.dispatched_by.presence)
        fact("Dispatched", @deployment.dispatched_at.present? ? timestamp(Time.zone.parse(@deployment.dispatched_at)) : nil)
      end
    end
  end

  def fact(label, value)
    return if value.blank?

    div(class: "flex flex-col vmd:flex-row vmd:items-baseline gap-0.5 vmd:gap-3 " \
               "px-3.5 py-2 border-b border-voodu-border") do
      span(class: "text-[11px] uppercase tracking-[0.06em] text-voodu-muted vmd:w-32 shrink-0") { label }
      span(class: "text-[12.5px] text-voodu-text-2 min-w-0 break-words") { value }
    end
  end

  def resources_card
    resources = @deployment.deployed_resources

    card = Components::UI::SectionCard.new(title: "Resources · #{resources.size}")

    render card do
      if resources.empty?
        no_resources
      else
        div(class: "flex flex-col") { resources.each { |resource| resource_row(resource) } }
      end
    end
  end

  # What the box printed while building and releasing. Collapsed on a deploy
  # that worked — the resources above are what a reader wants then — and open
  # on one that failed, where `error` is a single line and the cause sits in
  # the forty lines above it. The `pre` scrolls both ways inside the card so
  # a long `bundle install` line never widens the page.
  def log_card
    render Components::UI::SectionCard.new(title: "Log") do
      details(open: @deployment.status == "failed", class: "group") do
        summary(class: "flex items-center gap-2 px-3.5 py-2.5 cursor-pointer select-none " \
                       "text-[12px] text-voodu-text-2 hover:bg-voodu-hover list-none") do
          render Icon::ChevronRightOutline.new(class: "w-3 h-3 shrink-0 text-voodu-muted transition-transform group-open:rotate-90")
          span { "Build and release output" }
          span(class: "font-voodu-mono text-[11px] text-voodu-muted") { "#{@deployment.log.lines.size} lines" }
        end

        pre(class: "m-0 px-3.5 py-3 max-h-[480px] overflow-x-auto overflow-y-auto whitespace-pre " \
                   "font-voodu-mono text-[11.5px] leading-relaxed text-voodu-text-2 bg-voodu-bg-2 " \
                   "border-t border-voodu-border") { @deployment.log }
      end
    end
  end

  # The link the whole screen exists for: from a commit to the containers
  # running it, and (through the pod page) back again.
  def resource_row(resource)
    pods = @deployment.pods_for(resource)

    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 px-3.5 py-2.5 " \
               "border-b border-voodu-border last:border-b-0") do
      div(class: "flex flex-col min-w-0 basis-full vmd:basis-auto vmd:flex-1") do
        span(class: "font-voodu-mono text-[12.5px] text-voodu-text truncate") { resource.label }
        span(class: "text-[11px] text-voodu-muted") { resource.kind.to_s }
      end

      div(class: "flex flex-wrap items-center gap-1.5 shrink-0") do
        pods.any? ? pods.each { |pod| pod_link(pod) } : gone_note
      end
    end
  end

  def pod_link(pod)
    a(href: pod_path(name: pod.container_name),
      class: "px-2 py-1 border border-voodu-border bg-voodu-surface-2 no-underline " \
             "font-voodu-mono text-[11.5px] text-voodu-link hover:border-voodu-border-2") do
      pod.container_name
    end
  end

  # A real answer, not a gap. A resource deployed last week whose containers
  # are gone is exactly what somebody opens this page to find out.
  def gone_note
    span(class: "text-[11.5px] text-voodu-muted") { "no containers running this" }
  end

  def no_resources
    div(class: "px-3.5 py-6 text-center") do
      p(class: "m-0 text-[12.5px] text-voodu-muted") do
        if @deployment.status == "succeeded"
          "This deploy reported no resources. The server may be running an older controller."
        else
          "Nothing was applied."
        end
      end
    end
  end

  def timestamp(value)
    return nil if value.nil?

    WebTime.in_zone(value).strftime("%Y-%m-%d %H:%M:%S")
  end

  def duration
    return nil if @deployment.started_at.nil? || @deployment.finished_at.nil?

    seconds = (@deployment.finished_at - @deployment.started_at).round

    (seconds < 60) ? "#{seconds}s" : "#{seconds / 60}m #{seconds % 60}s"
  end
end
