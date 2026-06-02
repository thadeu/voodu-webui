# Turbo Drive disconnects <turbo-cable-stream-source> elements on
# navigation. During page caching/restoration the same signed stream
# (island-state-*, metrics-*) can fire `unsubscribe` twice: the first
# removes the subscription, the second finds nothing and ActionCable's
# `find` raises "Unable to find subscription with identifier".
#
# The error is caught upstream (the connection survives) but floods the
# log on every page leave. Make `remove` idempotent so the duplicate
# unsubscribe is a quiet no-op instead of a logged RuntimeError.
Rails.application.config.to_prepare do
  ActionCable::Connection::Subscriptions.prepend(
    Module.new do
      def remove(data)
        return super if subscriptions.key?(data["identifier"])

        logger.info "Ignoring unsubscribe for unknown identifier: #{data['identifier']}"
      end
    end
  )
end
