# frozen_string_literal: true

# The base of every email: from Voodu at voodu.clowk.in (or MAIL_FROM), through
# 1billion. Only sent where Mailing.enabled? (our cloud console).
class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV["MAIL_FROM"].presence || "Voodu <hello@voodu.clowk.in>" }
  layout "mailer"
end
