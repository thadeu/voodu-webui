# frozen_string_literal: true

class StyleguideController < ApplicationController
  def index
    render Views::Styleguide::Index.new(**dashboard_context)
  end
end
