# frozen_string_literal: true

# The words on the play button's confirm, in one place for the two places the
# button lives (the table row and the deployment page).
#
# THE PERSON IS TOLD, NOT ASKED. The rule for what a play does is fixed — the
# first one re-runs the held row, every later one creates a new row — and the
# prompt says which of the two is about to happen. Cancelling costs nothing:
# the POST never leaves the browser, so nothing is created and nothing moves.
module Components::Deploys::DispatchPrompt
  def self.for(deployment)
    files = Array(deployment.held).to_sentence
    head = "Deploy #{deployment.short_sha} to #{deployment.server.name}? Applies #{files}."

    return head unless deployment.rerun?

    "#{head} This commit was already dispatched — the re-run is recorded as a NEW deployment, " \
      "and this one keeps its result."
  end
end
