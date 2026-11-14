class DataCacheClearJob < ApplicationJob
  queue_as :low_priority

  # Market data (exchange rates and security prices) is shared by every family, so after
  # deleting it every family resyncs to rebuild it. The requesting family also drops its
  # derived balances and holdings, as asked.
  def perform(family)
    ActiveRecord::Base.transaction do
      ExchangeRate.delete_all
      Security::Price.delete_all
      family.accounts.each do |account|
        account.balances.delete_all
        account.holdings.delete_all
      end
    end

    # After the commit, so no sync can run against the data before it is deleted
    Family.find_each(&:sync_later)
  end
end
