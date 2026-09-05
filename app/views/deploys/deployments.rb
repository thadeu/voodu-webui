# frozen_string_literal: true

# The Deployments tab: every push this server acted on.
#
# THE HALF THAT JUSTIFIES THE FEATURE LIVING IN THIS PRODUCT. Everything else
# in VooduCD could be a GitHub Action and a script. What could not is this: the
# CPU chart, the logs and the probe status this dashboard already draws, given
# a version anchor. "That spike started at the deploy of abc1234" stops being a
# deduction and becomes a link.
class Views::Deploys::Deployments < Views::Deploys::Shell
  private

  def tab = :deployments

  def subtitle = "Every push #{@current_server&.name} acted on, and what each one put on the box."

  def content
    div(data: {controller: "polling", polling_interval_value: DeploysController::POLL_MS}) do
      # `src` is what makes the tick work: the polling controller calls
      # frame.reload(), and reload() refetches src. Without it the call is a
      # silent no-op. The inline body renders immediately, so the first paint
      # is not blocked on the refetch.
      #
      # target: "_top" because the rows inside link to a deployment's DETAIL,
      # which is a page and not a fragment. Without it Turbo would look for
      # this frame in the detail response, not find one, and render
      # "Content missing" instead of navigating.
      turbo_frame_tag(DeploysController::FRAME, src: current_request_url, target: "_top") do
        render Components::Deploys::DeploymentsBody.new(data: @data)
      end
    end
  end

  # The frame refetches the CURRENT url, so a tick preserves the filters and
  # the cursor. Rebuilding it from the path alone would drag the reader back to
  # the newest page every few seconds — which reads as the screen having a mind
  # of its own rather than as a bug with a cause.
  def current_request_url
    request.fullpath
  end
end
