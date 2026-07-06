# frozen_string_literal: true

class StyleguideController < ApplicationController
  # /styleguide is server-less — it's an internal design reference
  # surface, not part of the monitoring UI.
  skip_before_action :require_server!

  def index
    render Views::Styleguide::Index.new(**dashboard_context)
  end
end
