# The accounts that count in past net worth, and for which days.
#
# Active accounts count on every day. A disabled account counts up to the day before
# it was disabled, so turning an account off does not rewrite the history it was part
# of. Drafts (unfinished setup) and accounts being deleted never count.
class BalanceSheet::HistoricalAccountScope
  def initialize(family, accounts: nil)
    @family = family
    @base = accounts || family.accounts
  end

  def relation
    base.counted_in_history
  end

  def account_ids
    accounts.map(&:id)
  end

  # { account_id => last day it counts } for the disabled accounts. Accounts that are
  # not listed count on every day.
  def active_until_dates
    @active_until_dates ||= begin
      zone = family.resolved_time_zone

      accounts.select(&:disabled?).to_h do |account|
        # A disabled account from before disabled_at existed has no stamp; its last
        # update is the closest record of when it was turned off.
        disabled_on = (account.disabled_at || account.updated_at).in_time_zone(zone).to_date
        [ account.id, disabled_on - 1.day ]
      end
    end
  end

  private
    attr_reader :family, :base

    def accounts
      @accounts ||= relation.select(:id, :status, :disabled_at, :updated_at).to_a
    end
end
