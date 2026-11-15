class Account::SyncCompleteEvent
  attr_reader :account

  Error = Class.new(StandardError)

  def initialize(account)
    @account = account
  end

  def broadcast
    # Replace account row in accounts list
    account.broadcast_replace_to(
      account.family,
      target: "account_#{account.id}",
      partial: "accounts/account",
      locals: { account: account }
    )

    # Replace the groups this account belongs to in both desktop and mobile sidebars
    sidebar_targets.each do |(tab, mobile_flag)|
      account.broadcast_replace_to(
        account.family,
        target: account_group.dom_id(tab: tab, mobile: mobile_flag),
        partial: "accounts/accountable_group",
        locals: { account_group: account_group, open: true, all_tab: tab == :all, mobile: mobile_flag }
      )
    end

    # If this is a manual, unlinked account (i.e. not part of a provider item),
    # trigger the family sync complete broadcast: it updates the net worth graph and
    # sends the sync toast, which refreshes the account page once the user is idle.
    # There is no account.broadcast_refresh here: it reloaded the page under an open
    # form and, with the toast, made the server render the page twice.
    unless account.linked?
      account.family.broadcast_sync_complete
    end
  end

  private
    # Returns an array of [tab, mobile?] tuples that should receive an update.
    # We broadcast to both the classification-specific tab and the "all" tab,
    # for desktop (mobile: false) and mobile (mobile: true) variants.
    def sidebar_targets
      return [] unless account_group.present?

      [
        [ account_group.classification.to_sym, false ],
        [ :all, false ],
        [ account_group.classification.to_sym, true ],
        [ :all, true ]
      ]
    end

    def account_group
      family_balance_sheet.account_groups.find do |group|
        group.accounts.any? { |a| a.id == account.id }
      end
    end

    def family_balance_sheet
      account.family.balance_sheet
    end
end
