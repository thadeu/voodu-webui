# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,

  # `pairs` is the KEY=VALUE block ConfigController#create accepts — a whole
  # .env of production secrets in one parameter. Without this it lands in the
  # request log verbatim, which would undo the point of asking the box not to
  # send values back: we would be writing them down on the way IN.
  :pairs
]
