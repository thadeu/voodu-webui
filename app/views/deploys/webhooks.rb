# frozen_string_literal: true

# The Webhooks tab: every delivery that arrived, and what became of it.
#
# THE TAB THAT ANSWERS "DID GITHUB CALL". Before this table existed, only a
# delivery that produced work left a trace — so a refused signature, a
# repository no server listed, and a webhook that never arrived were the same
# silence from inside the product. They are opposite problems.
class Views::Deploys::Webhooks < Views::Deploys::Shell
  private

  def tab = :webhooks

  # Named for the server: the table is fenced to what reached this box (see
  # WebhookReceiptsData#scope_for_org), and a subtitle claiming the whole
  # installation would promise rows the fence keeps out.
  def subtitle = "Every webhook that reached #{@data.server&.name || "this server"}, and what it did with each one."

  def content
    div(data: {controller: "polling", polling_interval_value: DeploysController::POLL_MS}) do
      turbo_frame_tag(DeploysController::WEBHOOKS_FRAME,
        src: request.fullpath, target: "_top") do
        render Components::Deploys::WebhooksBody.new(data: @data)
      end
    end
  end
end
