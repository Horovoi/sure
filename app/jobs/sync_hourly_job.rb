# Syncs the items of the enabled bank connection providers that opt in to hourly
# syncing (BankConnections.register(..., hourly: true)).
class SyncHourlyJob < ApplicationJob
  queue_as :scheduled

  def perform
    syncable_classes = BankConnections.enabled_providers.select(&:hourly?).map(&:item_class)

    if syncable_classes.empty?
      Rails.logger.info("Skipping hourly sync: no enabled bank connection syncs hourly")
      return
    end

    Rails.logger.info("Starting hourly sync")
    syncable_classes.each do |syncable_class|
      sync_items(syncable_class)
    end
    Rails.logger.info("Completed hourly sync")
  end

  private

    def sync_items(syncable_class)
      syncable_class.active.find_each do |item|
        item.sync_later
      rescue => e
        Rails.logger.error("Failed to sync #{syncable_class.name} #{item.id}: #{e.message}")
      end
    end
end
