# frozen_string_literal: true

# The preflight result, alone, for the frame that asked for it.
#
# A frame-only view rather than a re-render of the page: the operator is
# looking at an open repository card, and replacing the whole screen to show
# four lines would scroll them away from what they were reading.
class Views::Deploys::Preflight < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    render Components::Deploys::PreflightPanel.new(data: @data, run: true)
  end
end
