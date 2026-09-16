# frozen_string_literal: true

module Integrations
  # Integrations::GithubWebhooksController — where a push becomes a deployment.
  #
  # Reached by GitHub, with no session, no org and no user. It does NOT inherit
  # ApplicationController, for the same reasons Internal::PollerController does
  # not: there is no operator to sign in, no server in the URL to scope to, and
  # no browser to protect from CSRF. Everything this endpoint is allowed to do
  # comes out of two things — the HMAC, and the installation id in the payload.
  #
  # THE ORDER OF THE CHECKS IS THE DESIGN, and it is the order the ticket
  # states:
  #
  #   1. HMAC over the RAW body, before anything is parsed. A signature checked
  #      after parsing has already let unauthenticated bytes through a parser.
  #   2. Dedupe by delivery id. GitHub retries what it did not get a 2xx for,
  #      and retries the SAME id.
  #   3. Which servers listed this repository — the tenant scoping, and it is
  #      structural: the lookup starts from the installation, so a delivery
  #      cannot name an org that did not list it.
  #
  # What is NOT decided here: whether the push matches the trigger's branch or
  # its watch paths. That config lives in the customer's repository and on
  # their box, and only the box has read it. Answering here would mean holding
  # a second copy of it — one that can disagree with the one that runs.
  class GithubWebhooksController < ActionController::API
    # Every failure below returns a body GitHub shows in its delivery log. That
    # log is the only debugging surface a customer has for a webhook, so the
    # sentences are written for it — and they say what is wrong without saying
    # anything a caller who failed the HMAC did not already know.
    def create
      unless verified?
        # RECORDED, and that is the point of writing it here rather than just
        # refusing. A refused signature used to leave no trace at all, so
        # "GitHub never called" and "GitHub called and we rejected it" were the
        # same silence from inside the product — and they are opposite
        # problems. The payload is NOT stored: it did not verify, so it is
        # unauthenticated bytes we have no reason to keep.
        record(status: "refused_signature", payload: {})

        return render json: {error: "signature did not verify"}, status: :unauthorized
      end

      case event
      when "ping" then accept(status: "ignored") { render json: {ok: true} }
      when "push" then handle_push
      when "installation" then handle_installation
      else
        # 200, deliberately: an event we do not handle is not an error, and a
        # non-2xx would make GitHub retry it forever.
        accept(status: "ignored") { render json: {ok: true, ignored: event} }
      end
    end

    private

    # verified? — the HMAC, over the raw body.
    #
    # `request.raw_post` and never `params`: the signature covers the exact
    # bytes GitHub sent, and a re-serialised hash is not those bytes.
    #
    # Fails closed when no secret is configured. An installation that forgot
    # the secret must reject deliveries, not accept them unchecked — the second
    # is an endpoint anybody on the internet can post deploys to.
    def verified?
      secret = GithubSettings.current.webhook_secret

      return false if secret.blank?

      provided = request.headers["X-Hub-Signature-256"].to_s

      return false if provided.blank?

      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)

      # Constant time, so a caller cannot learn the signature one byte at a
      # time from how long the comparison took. secure_compare needs equal
      # lengths, which the digest guarantees for anything well-formed and the
      # bytesize check settles for anything else.
      return false unless provided.bytesize == expected.bytesize

      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    end

    def handle_push
      repo = payload.dig("repository", "full_name").to_s
      installation_id = payload.dig("installation", "id").to_s
      ref = payload["ref"].to_s
      sha = payload["after"].to_s

      # A branch delete arrives as a push whose `after` is all zeros. There is
      # no commit to deploy, and deploying the branch's last state would ship
      # code somebody just removed.
      if payload["deleted"] || sha.match?(/\A0+\z/)
        return accept(status: "skipped", reference: repo, reason: "branch deleted") do
          render json: {ok: true, skipped: "branch deleted"}
        end
      end

      # Branches and tags both deploy: the trigger file's `on.push` names
      # either (`branches:` / `tags:`), and the box matches the full ref so a
      # branch called `v1.0` never fires a tag pattern. The box still checks
      # the commit descends from the trigger's branch, so a tag on a stray
      # commit is refused there, with a reason, rather than skipped here
      # without one. Anything else GitHub can push (notes, pull refs) is
      # accepted and ignored — refusing makes GitHub retry a push nobody
      # wants.
      unless ref.start_with?("refs/heads/", "refs/tags/")
        return accept(status: "skipped", reference: repo, reason: "not a branch or tag") do
          render json: {ok: true, skipped: "not a branch or tag"}
        end
      end

      targets = Integration::Record.for_delivery("github", installation_id, repo)

      if targets.empty?
        # THE STATE THAT USED TO VANISH. A repository authorised on GitHub but
        # pointed at no server produces nothing, silently — and from the
        # outside that is indistinguishable from the webhook never arriving.
        reason = "no server listed #{repo}"

        return accept(status: "no_target", reference: repo, reason: reason) do
          render json: {ok: true, skipped: reason}
        end
      end

      receipt, fresh = record(
        status: "accepted", reference: repo,
        org_id: targets.first.integration.org_id,
        details: facts.merge("sha" => sha, "ref" => ref)
      )

      unless fresh
        return render json: {ok: true, duplicate: true, receipt: receipt&.id}
      end

      created = targets.filter_map { |target| queue(target, ref, sha, receipt) }

      # Enqueued AFTER every row exists, not one at a time inside the loop. A
      # job that starts while a sibling row is still being written would look
      # at `superseded_by` and see a repository with fewer pending deploys than
      # there are — and the whole point of that query is to see all of them.
      created.each { |deployment| DeployRunJob.perform_later(deployment.id) }

      render json: {ok: true, queued: created.size, deduped: targets.size - created.size}
    end

    def queue(target, ref, sha, receipt)
      Deployment.record_delivery(
        target: target,
        receipt: receipt,
        delivery_id: request.headers["X-GitHub-Delivery"].to_s.presence,
        ref: ref,
        sha: sha,
        # The same facts the receipt keeps, copied onto the deployment: the
        # deployments list must render without joining a receipt that
        # retention will eventually delete.
        details: facts
      )
    end

    # handle_installation — the customer removing the App on GitHub's side.
    #
    # Revoked and not deleted: the integration is what the deployment history
    # points at, and deleting it would take the record of what it deployed. A
    # revoked row deploys nothing and still explains the past.
    def handle_installation
      unless %w[deleted suspend].include?(payload["action"])
        return accept(status: "ignored") { render json: {ok: true} }
      end

      installation_id = payload.dig("installation", "id").to_s

      revoked = Integration::Record.where(provider: "github", external_id: installation_id).map do |integration|
        integration.revoke!
        integration.id
      end

      accept(status: "accepted", reason: "revoked #{revoked.size}") do
        render json: {ok: true, revoked: revoked.size}
      end
    end

    # ── the receipt ────────────────────────────────────────────────────────

    def event = request.headers["X-GitHub-Event"].to_s.presence || "unknown"

    # Parsed once per request. WHICH FIELDS WE ARE ALLOWED TO SHOW is decided
    # in one place — see Integration::Github::Push, and in particular what it
    # refuses to take.
    def facts = @facts ||= Integration::Github::Push.new(payload).facts

    def delivery_id = request.headers["X-GitHub-Delivery"].to_s.presence

    # record — one row per delivery, whatever the outcome.
    #
    # Never allowed to break the response. A provider that gets a 500 retries,
    # and retrying because our BOOKKEEPING failed would turn a logging problem
    # into a delivery storm — while the work itself already succeeded.
    def record(status:, payload: nil, reference: nil, org_id: nil, details: {}, reason: nil)
      Webhook::Receipt.record(
        provider: "github", event: event, status: status, external_id: delivery_id,
        reference: reference, org_id: org_id,
        payload: payload.nil? ? payload_for_storage : payload,
        details: details.merge({"reason" => reason}.compact)
      )
    rescue => e
      Rails.logger.error("[github] could not record the delivery: #{e.class}: #{e.message}")

      [nil, true]
    end

    # accept — record the outcome, then answer.
    #
    # In this order because the answer is what ends the request: a provider
    # that has its 200 may close the connection, and bookkeeping done after
    # that is bookkeeping that sometimes does not happen.
    def accept(status:, reference: nil, reason: nil)
      record(status: status, reference: reference, reason: reason)

      yield
    end

    # The body, capped. A receipt is evidence of what arrived, not an archive:
    # a provider can send megabytes, and a table that stores every byte of
    # every delivery is a table that becomes the reason to delete the feature.
    MAX_PAYLOAD = 64 * 1024

    def payload_for_storage
      return {} if request.raw_post.bytesize > MAX_PAYLOAD

      payload
    end

    def payload
      @payload ||= JSON.parse(request.raw_post)
    rescue JSON::ParserError
      {}
    end
  end
end
