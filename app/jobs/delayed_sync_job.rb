# Asks for a sync of a syncable (a provider item) at a later time, e.g. once a rate
# limited request slot is free. The sync itself runs through Syncable#sync_later, so it
# joins a sync that is already pending or running.
class DelayedSyncJob < ApplicationJob
  queue_as :medium_priority

  discard_on ActiveJob::DeserializationError

  def perform(syncable)
    return if syncable.respond_to?(:scheduled_for_deletion?) && syncable.scheduled_for_deletion?

    syncable.sync_later
  end
end
