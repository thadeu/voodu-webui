# frozen_string_literal: true

# "Write to us" (the account menu) and "Email us" (the Enterprise card): a
# message to support, sent by email (SupportMailer). Anyone signed in may write.
# Only where this installation sends mail; elsewhere this screen sends people back.
class Ops::ContactController < ApplicationController
  skip_before_action :require_server!

  authorize_anywhere :read

  before_action :require_mailing

  def new
    render Views::Ops::Contact::New.new(current_path: request.path, servers: sidebar_servers)
  end

  def create
    message = params[:message].to_s.strip.first(5000)

    return redirect_to(ops_contact_path, alert: "Write a message before you send it.") if message.empty?

    SupportMailer.contact(Current.user, message).deliver_later

    redirect_to root_path(org_id: nil, server_key: nil), notice: "Thanks! Your message is on its way. We answer at #{Current.user.email}."
  end

  private

  def require_mailing
    redirect_to root_path(org_id: nil, server_key: nil) unless Mailing.enabled?
  end
end
