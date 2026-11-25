# frozen_string_literal: true

# SupportMailer — "Email us" from the console: the message goes to support,
# with the person as Reply-To, so the answer reaches them.
class SupportMailer < ApplicationMailer
  TO = "support@voodu.clowk.in"

  def contact(user, message)
    @user = user
    @message = message

    mail(to: TO, reply_to: user.email, subject: "Contact - #{user.name.presence || user.email}")
  end
end
