# frozen_string_literal: true

class AlertsController < ApplicationController
  def index
    render Views::Alerts::Index.new(**dashboard_context)
  end
end
