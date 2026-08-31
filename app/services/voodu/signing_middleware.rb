# frozen_string_literal: true

module Voodu
  # Signs every request on its way out.
  #
  # Faraday middleware rather than a header set when the connection is built,
  # because a signature covers the method, path, query and body — none of which
  # exist yet at build time. Here the request is final: what gets signed is
  # exactly what goes on the wire, with no chance of the two drifting.
  #
  # Registered per connection in Voodu::Client.
  class SigningMiddleware < Faraday::Middleware
    def initialize(app, pat:)
      super(app)
      @pat = pat
    end

    def on_request(env)
      env.request_headers["Authorization"] = Signature.header(
        pat: @pat,
        method: env.method,
        path: env.url.path,
        query: env.url.query,
        body: env.body
      )
    end
  end
end
