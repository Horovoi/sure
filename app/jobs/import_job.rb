class ImportJob < ApplicationJob
  queue_as :high_priority

  # Only an import that publish_later moved to importing is published; a duplicate
  # or late job for an import in any other state does nothing.
  def perform(import)
    unless import.importing?
      Rails.logger.warn("ImportJob: import #{import.id} is #{import.status}, not importing. Skipping.")
      return
    end

    import.publish
  end
end
