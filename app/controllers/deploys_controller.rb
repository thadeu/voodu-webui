# frozen_string_literal: true

# VooduCD for one server: which repositories deploy here, and what the box
# reads out of each one.
#
# TWO GATES, and they are not the same question:
#
#   `deploy_plane?` — does this installation have the feature at all. A box
#   without it does not reach the screen OR the endpoint, so hiding the nav
#   item is not what enforces it.
#
#   `manage_deploys` — may THIS person configure it. Admin, beside
#   manage_servers: an admin can already restart a pod, install a plugin and
#   reveal the PAT that is the whole controller, so deploying from a repository
#   the org already authorized on GitHub is smaller than any of those.
#
# The whole screen and not only its writes, for the reason PluginsController
# gives: a read-only version of this page is not a feature anybody asked for.
class DeploysController < ApplicationController
  authorize :manage_deploys

  before_action :require_deploy_plane!

  # The frame the Deployments tab polls, and the one its filters target.
  FRAME = "deploys-deployments"

  WEBHOOKS_FRAME = "deploys-webhooks"

  # 30s, matching the metrics warehouse tick. A deploy takes tens of seconds,
  # so a tighter poll would be a lot of requests to watch one row change state.
  POLL_MS = 30_000

  def repositories
    @data = current_server && DeploysData.new(
      server: current_server, org: current_org, repo: params[:repo], file: params[:file]
    )

    render Views::Deploys::Repositories.new(**dashboard_context.merge(data: @data))
  end

  def deployments
    @data = current_server && DeploymentsData.new(server: current_server, params: params)

    # A Turbo-Frame request re-renders only the table, so a poll tick (and
    # every filter change) costs the body rather than the whole page.
    if request.headers["Turbo-Frame"] == FRAME
      render Views::Deploys::DeploymentsFrame.new(data: @data), layout: false
    else
      render Views::Deploys::Deployments.new(**dashboard_context.merge(data: @data))
    end
  end

  def deployment
    @data = current_server && DeploymentsData.new(server: current_server, id: params[:id])

    # A deployment of another server and one that never existed are the same
    # answer: the query is scoped, so there is nothing to tell apart and
    # nothing to leak by trying.
    if @data&.deployment.nil?
      return redirect_to deploys_deployments_path, alert: "That deployment is not on this server."
    end

    render Views::Deploys::Deployment.new(**dashboard_context.merge(data: @data))
  end

  # dispatch_deployment — the play button. Not `dispatch`: that is
  # ActionController::Metal's own entry point, and defining it here
  # replaces the method Rails calls to run every action.
  #
  # Releases a push the box held because its trigger file said
  # `deploy: manual`. The row goes back through DeployRunJob as a dispatch, so
  # the concurrency key and the ancestry check on the box both still apply —
  # this is a person choosing a commit, not a person bypassing anything.
  #
  # Refused (not ignored) when the row is not holdable: a double click lands
  # here twice, and the second must not re-queue a deploy already running.
  def dispatch_deployment
    deployment = current_server&.deployments&.find_by(id: params[:id])

    if deployment.nil?
      return redirect_to deploys_deployments_path, alert: "That deployment is not on this server."
    end

    unless deployment.dispatchable?
      return redirect_to deploys_deployment_path(id: deployment.id),
        alert: "This deployment has nothing waiting to be dispatched."
    end

    run = deployment.dispatch!(by: Current.user&.email.presence || Current.user&.id)
    DeployRunJob.perform_later(run.id)

    redirect_to deploys_deployment_path(id: run.id),
      notice: "Deploying #{run.short_sha} — #{Array(run.held).to_sentence}."
  end

  # preflight — the four questions, on demand.
  #
  # Its own action rather than part of `index` because it costs a round trip to
  # the box AND a GitHub call behind it: folding it into the page would spend
  # both every time somebody clicks a card. Frame-only, so the answer lands
  # where the operator is already looking.
  def preflight
    @data = current_server && DeploysData.new(
      server: current_server, org: current_org, repo: params[:repo]
    )

    if @data&.selected.nil?
      return redirect_to deploys_repositories_path, alert: "That repository is not connected to this server."
    end

    render Views::Deploys::Preflight.new(data: @data), layout: false
  end

  # connect_repo — point a repository at THIS server, in one action.
  #
  # Two writes, and the ORDER IS THE DESIGN:
  #
  #   1. the trigger, on the box
  #   2. the listing entry, in our database
  #
  # Box first, because the two failure shapes are not equally bad. A trigger on
  # the box that nothing points at deploys nothing — it is inert until somebody
  # lists it. A listing entry naming a trigger that was never created is the
  # opposite: every push to that repository queues a deployment that fails at
  # the box, and the operator sees a screen saying the repository is connected.
  # Inert beats actively broken.
  #
  # THE SECURITY TRADE, written down where it happens: this lets the console
  # widen what the box accepts. The alternative is every developer holding SSH
  # to production so one of them can run `vd deploy trigger create`. The
  # controller records every trigger change in its activity trail, which is the
  # other half of the trade — see recordTriggerChange there.
  def connect_repo
    repo = params[:repo].to_s.strip
    branch = params[:branch].to_s.strip
    scopes = parse_scopes(params[:allow_scopes])

    return refuse("Pick a repository first.") if repo.blank?

    # Checked BEFORE the box call. Without it the trigger would be created on
    # the server and then `add_repo!` would raise on nil — leaving an
    # authorization nothing points at and a 500 where a sentence belongs.
    return refuse("Connect GitHub before pointing a repository here.") if integration.nil?

    # Checked BEFORE the box call. Without it the trigger would be created on
    # the server and then `add_repo!` would raise on nil — leaving an
    # authorization nothing points at and a 500 where a sentence belongs.
    return refuse("A branch is required — it is what a deploy's commit must descend from.") if branch.blank?

    # Refused here as well as by the box, because the message matters: the box
    # says "allow_scopes is required", and the person is looking at a field
    # labeled Scopes.
    if scopes.empty?
      return refuse("Name at least one scope. A trigger that allows nothing can deploy nothing.")
    end

    trigger = voodu_client.create_deploy_trigger(repo: repo, branch: branch, allow_scopes: scopes)

    integration.add_repo!(repo: repo, server_id: current_server.id, trigger_id: trigger["id"])

    redirect_to deploys_repositories_path(repo: repo),
      notice: "#{repo} now deploys to #{current_server.name} on #{branch}."
  rescue Voodu::Client::Error => e
    refuse(trigger_failure(e), repo: repo)
  rescue ActiveRecord::ActiveRecordError => e
    # The trigger exists on the box and we could not write our half. Said
    # plainly rather than swallowed: the operator needs to know there is
    # something on their box that this screen will not show them.
    Rails.logger.error("[deploys] listed #{repo} on the box but not here: #{e.class}")
    refuse("The trigger was created on #{current_server.name}, but we could not record it here. " + "Try again — a duplicate trigger will be refused by the server.", repo: repo)
  end

  # disconnect_repo — stop deploying a repository here.
  #
  # The reverse order, for the same reason read the other way: OUR entry goes
  # first, because that is what stops the next push from queueing anything. If
  # the box call then fails, what remains is an inert trigger nothing points
  # at — and the operator is told, rather than left with a screen that says the
  # repository is disconnected while the box still holds the authorization.
  def disconnect_repo
    repo = params[:repo].to_s.strip
    entry = integration&.repos_for_server(current_server)&.find { |e| e.matches?(repo) }

    return refuse("#{repo} is not connected to this server.") if entry.nil?

    integration.remove_repo!(repo: repo, server_id: current_server.id)

    if entry.trigger_id.present?
      begin
        voodu_client.delete_deploy_trigger(entry.trigger_id)
      rescue Voodu::Client::NotFoundError
        # Already gone from the box — somebody ran `vd deploy trigger delete`.
        # Nothing to report: the outcome the operator asked for is the outcome.
        nil
      rescue Voodu::Client::Error => e
        Rails.logger.warn("[deploys] left trigger #{entry.trigger_id} on the box: #{e.class}")

        return redirect_to deploys_repositories_path,
          alert: "#{repo} no longer deploys here, but its trigger is still on #{current_server.name}. " + "It fires nothing — remove it with `vd deploy trigger delete #{entry.trigger_id}`."
      end
    end

    redirect_to deploys_repositories_path, notice: "#{repo} no longer deploys to #{current_server.name}."
  end

  # webhooks — every delivery that arrived, and what became of it.
  #
  # Org-scoped rather than server-scoped, and that is not an oversight: a
  # delivery that failed its signature, or that matched no server, has no
  # server to be filed under. Those are exactly the rows somebody comes here to
  # find, so filing the tab by server would hide them.
  def webhooks
    @data = WebhookReceiptsData.new(org: current_org, server: current_server, params: params)

    if request.headers["Turbo-Frame"] == WEBHOOKS_FRAME
      render Views::Deploys::WebhooksFrame.new(data: @data), layout: false
    else
      render Views::Deploys::Webhooks.new(**dashboard_context.merge(data: @data))
    end
  end

  def webhook
    @data = WebhookReceiptsData.new(org: current_org, server: current_server, id: params[:id])

    if @data.receipt.nil?
      return redirect_to deploys_webhooks_path, alert: "That delivery is not on this installation."
    end

    render Views::Deploys::Webhook.new(**dashboard_context.merge(data: @data))
  end

  # refresh — drop the cached repository listing.
  #
  # Exists because the list changes on github.com, where we have no way of
  # being told: somebody adds a repository to the installation and comes back
  # here expecting to see it. Without this the only answer is "wait five
  # minutes", which is not an answer anybody accepts about their own click.
  def refresh
    if current_server
      DeploysData.new(server: current_server, org: current_org).refresh!
    end

    redirect_to deploys_repositories_path, notice: "Repository list refreshed."
  end

  private

  def integration
    @integration ||= Integration::Record.active.find_by(org: current_org, provider: "github")
  end

  # Comma or newline separated, because both are what people type: the CLI
  # takes `--scope a,b` and a form field invites one per line.
  def parse_scopes(raw)
    raw.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?).uniq
  end

  # The failures an operator actually hits, named. Each has a different fix,
  # and "could not create the trigger" names none of them.
  def trigger_failure(error)
    message = error.message.to_s

    return "#{current_server.name} did not answer." if error.is_a?(Voodu::Client::TransportError)

    if error.is_a?(Voodu::Client::AuthError)
      return "This server's token cannot create triggers — it needs the deploy scope."
    end

    return "That repository already deploys here on that branch." if message.include?("already authorizes")

    "The server refused it: #{message}"
  end

  def refuse(message, repo: nil)
    redirect_to deploys_repositories_path(repo.present? ? {repo: repo} : {}), alert: message
  end

  def require_deploy_plane!
    return if entitlements.deploy_plane?

    redirect_to server_root_path,
      alert: "Deploying from GitHub is not part of this plan."
  end
end
