class Family::SyncCompleteEvent
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def broadcast
    # Dashboard partials can occasionally raise when rendered from background jobs
    # (e.g., if intermediate series values are nil during a sync). Make broadcasts
    # resilient so a post-sync UI refresh never causes the overall sync to report an error.
    begin
      family.broadcast_replace(
        target: "balance-sheet",
        partial: "pages/dashboard/balance_sheet",
        locals: { balance_sheet: family.balance_sheet }
      )
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent balance_sheet broadcast failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end

    begin
      family.broadcast_replace(
        target: "net-worth-chart",
        partial: "pages/dashboard/net_worth_chart",
        locals: { balance_sheet: family.balance_sheet, period: Period.last_30_days }
      )
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent net_worth_chart broadcast failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end

    # Replace the #sync-toast slot instead of refreshing every open page. The
    # sync-toast Stimulus controller morph-refreshes an idle page, and leaves the
    # toast up (or hidden until a dialog closes) while someone is typing, so a
    # background sync never wipes a half-filled form. The partial has no user data
    # (Current.user is nil in the job); each browser re-fetches its own page.
    begin
      family.broadcast_replace_to(
        family,
        target: "sync-toast",
        partial: "shared/notifications/sync_toast"
      )
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent sync_toast broadcast failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end

    # Replace generated subscription charges with their real charges (debounced). Scheduled
    # first, so pattern identification sees the real charges.
    begin
      RecurringTransaction.reconcile_charges_for(family)
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent recurring charge reconciliation failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end

    # Schedule recurring transaction pattern identification (debounced to run after all syncs complete)
    begin
      RecurringTransaction.identify_patterns_for(family)
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent recurring transaction identification failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end
  end
end
