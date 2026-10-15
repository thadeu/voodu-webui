# frozen_string_literal: true

# FswapiSyncOrchestratorJob — every 15s (config/recurring.yml), one
# FswapiSyncServerJob per server that has the voodu-fswapi plugin installed
# (System#plugin_installed?, from the /system sync). A server without the
# plugin costs nothing: no job, no request.
#
# Not demand-driven like the first HEP3 poller: the overview IS the history of
# the FreeSWITCH page, so it has to be collecting before anyone opens it.
class FswapiSyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Server.find_each do |server|
      next unless server.plugin_installed?("fswapi")

      FswapiSyncServerJob.perform_later(server.id)
    end
  end
end
