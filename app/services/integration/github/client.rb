# frozen_string_literal: true

# Integration::Github::Client — what the control plane asks GitHub.
#
# THE SECOND HALF of App authentication: the JWT proves we are the App, and
# these calls trade it for a token scoped to ONE customer's installation — and
# within that, to the repositories they selected when they installed it.
#
# The token that reaches a customer's box comes from here, lives one hour, and
# is never stored. It is minted per request and passed in the call that needs
# it; a field holding one would outlive the request that was authorised to use
# it.
#
# The box has its own GitHub client (internal/github in clowk-voodu) for
# reading repository contents. This one is deliberately narrow: it does the
# things only the App's private key can do, and the private key never leaves
# this installation.
class Integration::Github::Client
  API = "https://api.github.com"

  # Short, because every call here is on a path a person is waiting on — a
  # screen, or a webhook GitHub will retry if we are slow.
  TIMEOUT = 10

  class Error < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      @status = status
      super(message)
    end

    # A token problem and a missing installation have completely different
    # fixes, so a caller has to be able to tell them apart.
    def unauthorized? = [401, 403].include?(status)

    def not_found? = status == 404
  end

  def initialize(settings = GithubSettings.current)
    @settings = settings
  end

  # installation — who this installation belongs to.
  #
  # Called once at connect time, for the account login the screen shows. The
  # id alone is a number; "acme-corp" is what a person recognises.
  def installation(installation_id)
    get("/app/installations/#{installation_id}", auth: "Bearer #{app_jwt}")
  end

  # installation_token — the credential that reaches the customer's box.
  #
  # One hour, one installation, read-only on the repositories the customer
  # selected. Minted per deploy and per preflight; never stored, never logged.
  def installation_token(installation_id)
    body = post("/app/installations/#{installation_id}/access_tokens", auth: "Bearer #{app_jwt}")

    token = body["token"]

    raise Error, "GitHub returned no token for installation #{installation_id}" if token.blank?

    token
  end

  # repositories — which repositories this installation covers.
  #
  # The customer chose these on GitHub's own screen when they installed the
  # App: one of a hundred and seventy, if that is what they picked. We cannot
  # widen it, and the token cannot reach past it.
  #
  # Paged, because an installation on "All repositories" for a large org is
  # not a list we get to assume is short.
  def repositories(installation_id)
    token = installation_token(installation_id)
    out = []
    page = 1

    loop do
      body = get("/installation/repositories?per_page=100&page=#{page}", auth: "Bearer #{token}")
      batch = Array(body["repositories"])

      out.concat(batch)

      # Stops on a short page rather than on total_count: a repository added
      # between two pages would make the count and the pages disagree, and
      # trusting the count would loop past the end.
      break if batch.size < 100

      page += 1

      # A hard stop, because an installation that keeps answering full pages
      # forever is a bug somewhere and this should not become an infinite loop
      # inside a web request.
      break if page > 20
    end

    out
  end

  private

  def app_jwt = Integration::Github::AppJwt.generate(@settings)

  def get(path, auth:) = request(:get, path, auth: auth)

  def post(path, auth:) = request(:post, path, auth: auth)

  def request(method, path, auth:)
    response = connection.public_send(method, path) do |req|
      req.headers["Authorization"] = auth
      req.headers["Accept"] = "application/vnd.github+json"
      req.headers["X-GitHub-Api-Version"] = "2022-11-28"
    end

    return response.body if response.success?

    # The body is NOT echoed. A GitHub error can quote the request back,
    # including the credential, and this string reaches a screen and a log.
    raise Error.new("GitHub #{path} returned #{response.status}", status: response.status)
  rescue Faraday::Error => e
    raise Error, "could not reach GitHub: #{e.class}"
  end

  def connection
    @connection ||= Faraday.new(url: API) do |f|
      f.request :json
      f.response :json, content_type: /\bjson$/
      f.options.timeout = TIMEOUT
      f.options.open_timeout = TIMEOUT
    end
  end
end
