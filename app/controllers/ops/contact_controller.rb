# frozen_string_literal: true

# "Email us" from the Enterprise card: a message to support, sent by email
# (SupportMailer). Only where this installation sends mail; elsewhere the card
# keeps its mailto link and this screen sends people back.
class Ops::ContactController < ApplicationController
  skip_before_action :require_server!

  authorize_anywhere :manage_account

  before_action :require_mailing

  def new
    render Views::Ops::Contact::New.new(current_path: request.path, servers: sidebar_servers)
  end

  def create
    message = params[:message].to_s.strip.first(5000)

    return redirect_to(ops_contact_path, alert: "Write a message before you send it.") if message.empty?

    SupportMailer.contact(Current.user, message).deliver_later

    redirect_to ops_license_path, notice: "Thanks! Your message is on its way. We answer at #{Current.user.email}."
  end

  private

  def require_mailing
    redirect_to ops_license_path unless Mailing.enabled?
  end
end
