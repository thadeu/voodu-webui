# frozen_string_literal: true

# Environment variables of one pod, edited where they are read.
#
# ## Why this lives on the pod page and not on a screen of its own
#
# It had one — a /config screen with a bucket picker asking for a scope and an
# app. It was removed, and the reason is worth keeping: the operator already
# knows which pod they mean, because they are looking at it. Making them name
# the bucket again was asking them to re-derive something the URL already said.
#
# ## The bucket
#
# A pod named `runa-pg.0` is scope `runa`, resource `pg`, so the writes here
# land in the APP-level bucket (scope + name). Never the scope-level one: from
# a pod page "set this variable" means this app, and quietly writing a value
# every app in the scope inherits is a blast radius nobody asked for.
#
# ## Two different acts behind one drawer
#
#   edit     — the key is already in the config bucket. Saving changes it.
#   override — the key came from the IMAGE. Saving CREATES a config key that
#              shadows it, permanently, including across future images.
#
# The drawer says which one it is. They are the same form because they submit
# the same request; they are labeled differently because they are not the
# same decision.
class PodEnvController < ApplicationController
  # Matches PluginsController and the old config screen: setting a production
  # variable restarts the containers that read it, which is closer to
  # installing a plugin than to reading a log.
  authorize :manage_servers

  # new / edit — the drawer body. GET, because opening a form changes nothing.
  def new
    render Views::PodEnv::Form.new(**form_context(key: nil)), layout: false
  end

  def edit
    render Views::PodEnv::Form.new(**form_context(key: params[:key].to_s)), layout: false
  end

  # reveal — one value, fetched because somebody clicked the eye.
  #
  # THE VALUE IS NEVER IN THE PAGE UNTIL THIS RUNS. Not in a hidden span, not
  # in a data attribute, not in a copy button's payload. That is the whole
  # point of it being a request rather than a toggle: a page that ships every
  # value and masks them in CSS is a page where one script, one extension, or
  # one "inspect element" reads the lot — and where the mask is theatre over
  # something already handed out.
  #
  # WHICH VALUE it answers with is decided by WHERE it was asked from, not by
  # where the variable came from:
  #
  #   from a card row (:inline) → the CONTAINER's value, out of our warehouse
  #                               row. The card is a list of what the container
  #                               has, so that is the value the row is about.
  #   from the drawer (:field)  → the CONFIG BUCKET's value, from the box. The
  #                               drawer edits the bucket, and pre-filling it
  #                               with the container's value would invite
  #                               saving something that was never in there.
  #
  # The two genuinely differ — a variable set and not yet restarted into is the
  # everyday case — and deciding by origin instead would have made an
  # unreachable box render a value as "(empty)": saying a variable is blank
  # when we merely could not ask.
  def reveal
    key = params[:key].to_s

    return head :bad_request if key.blank?
    return head :not_found if pod.nil?

    if variant == :field
      return reveal_from_bucket(key)
    end

    render_value(key, container_value(key))
  end

  def create
    return unless require_bucket!

    key = params[:key].to_s.strip

    return refuse("Name the variable.") if key.blank?
    return refuse(BAD_KEY) unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

    voodu_client.set_config(
      scope: bucket_scope, name: bucket_name, vars: {key => params[:value].to_s},
      restart: params[:restart] != "false"
    )

    # The KEY in the notice, never the value: this string reaches a flash,
    # which lives in the session store, and a log line.
    redirect_to pod_path(name: pod_name), notice: "#{key} set on #{bucket_label}."
  rescue Voodu::Client::Error => e
    refuse(write_failure(e))
  end

  def destroy
    return unless require_bucket!

    key = params[:key].to_s

    return refuse("No variable named.") if key.blank?

    voodu_client.delete_config(
      scope: bucket_scope, name: bucket_name, keys: [key],
      restart: params[:restart] != "false"
    )

    redirect_to pod_path(name: pod_name), notice: "#{key} removed from #{bucket_label}."
  rescue Voodu::Client::Error => e
    refuse(write_failure(e))
  end

  private

  BAD_KEY = "A variable name can hold letters, digits and underscores, " \
            "and cannot start with a digit."

  def pod_name = params[:pod_name].to_s

  # pod — the warehouse row for the container in the URL.
  #
  # SCOPED TO THE CURRENT SERVER, which is what makes this the tenant boundary:
  # a container name from another org's screen finds nothing here, the same way
  # a made-up one does.
  def pod
    return @pod if defined?(@pod)

    @pod = current_server&.pods&.find_by(container_name: pod_name)
  end

  # The bucket these writes land in, read from the POD ROW and never parsed out
  # of the container name.
  #
  # Parsing was the obvious shortcut and it is wrong. `PodDetailData#split_name`
  # splits on the FIRST hyphen, so `clowk-lp-web` yields scope `clowk` rather
  # than `clowk-lp` — its own comment claims otherwise. That is tolerable in a
  # display fallback and unacceptable here: a wrong split aims a WRITE at
  # another app's bucket, and the operator would see a variable they set go
  # somewhere they never named.
  #
  # The row carries the real `scope` and `resource_name`, written by the sync
  # from what the box reports.
  def bucket_scope = pod&.scope

  def bucket_name = pod&.resource_name

  def bucket_label = "#{bucket_scope}/#{bucket_name}"

  # Refuses rather than guesses. A pod the warehouse has not seen has no bucket
  # we can name, and writing to one we invented is the failure this whole
  # method exists to prevent.
  def require_bucket!
    return true if bucket_scope.present? && bucket_name.present?

    redirect_to pods_path,
      alert: "We do not know which config bucket #{pod_name} belongs to yet. " \
             "Wait for the next sync, or set it with `vd config:set` on the box."

    false
  end

  def form_context(key:)
    {
      pod_name: pod_name,
      bucket_label: bucket_label,
      key: key,
      # Whether this key is already ours decides which of the two acts the
      # drawer is performing, and therefore what it says.
      from_config: key.present? && config_keys.include?(key)
    }
  end

  # `field` renders an editable textarea for the drawer; `inline` renders text
  # beside a copy button for a list row.
  def variant = (params[:variant] == "field") ? :field : :inline

  def reveal_from_bucket(key)
    return render_value(key, nil, error: "This pod has no config bucket we can name.") if bucket_scope.blank?

    render_value(key, voodu_client.config_value(
      scope: bucket_scope, name: bucket_name, key: key, merge: false
    ))
  rescue Voodu::Client::Error => e
    render_value(key, nil, error: reveal_failure(e))
  end

  # The container's reported env, out of the row the state sync already wrote.
  # No round trip: this value is in our database either way — what changes is
  # that it stops being in every rendered page.
  def container_value(key)
    env = pod.payload_hash&.dig("env")

    env.is_a?(Hash) ? env[key] : nil
  end

  def render_value(key, value, error: nil)
    render Views::PodEnv::Value.new(
      key: key, value: value, error: error, variant: variant, pod_name: pod_name
    ), layout: false
  end

  def config_keys
    @config_keys ||= begin
      return @config_keys = Set.new if bucket_scope.blank?

      rows = voodu_client.config_keys(scope: bucket_scope, name: bucket_name, merge: false)

      rows.filter_map { |row| row["key"].presence }.to_set
    rescue Voodu::Client::Error
      Set.new
    end
  end

  def reveal_failure(error)
    return "This server's token cannot read config — it needs config:read." if error.is_a?(Voodu::Client::AuthError)
    return "Not set in #{bucket_label}." if error.is_a?(Voodu::Client::NotFoundError)

    "Could not read it: #{error.message}"
  end

  def write_failure(error)
    return "#{current_server.name} did not answer." if error.is_a?(Voodu::Client::TransportError)

    if error.is_a?(Voodu::Client::AuthError)
      return "This server's token cannot change config — it needs the config scope."
    end

    "The server refused it: #{error.message}"
  end

  def refuse(message)
    redirect_to pod_path(name: pod_name), alert: message
  end
end
