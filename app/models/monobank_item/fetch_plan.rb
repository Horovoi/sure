# Decides which statement window a connection fetches next. One window is one
# request: at most 31 days and, when monobank returns a full page of 500 rows, the
# rest of that window is fetched as further pages (page_from..page_to).
#
# Order: windows of fresh data first (first fetch and forward), then gaps, then the
# backfill of older history; least recently fetched first within a kind.
#
#   page     page_to set: continue the cut window
#   first    nothing fetched yet: the last 31 days (not before the target start)
#   gap      the last fetch is older than 31 days: walk forward from it
#   forward  new activity: when the client-info balance changed since the last
#            forward fetch, open holds need a recheck, the last forward fetch is a day
#            old, or "Sync now" asked for it
#   backfill older history down to the target start
#
# The target start is the cut-over date minus 3 days for an account linked to
# hand-kept history (so the claim can see the overlap), else the product's or the
# connection's start date, else MONOBANK_INITIAL_HISTORY_DAYS ago.
class MonobankItem::FetchPlan
  Window = Data.define(:monobank_account, :from, :to, :kind)

  SPAN = 31.days
  FORWARD_STALE_AFTER = 24.hours
  HOLD_RECHECK_AFTER = 50.minutes
  HOLD_RETENTION = 31.days
  CUTOVER_OVERLAP = 3.days
  PRIORITY = { first: 0, forward: 0, gap: 1, backfill: 2 }.freeze

  class << self
    def target_start_for(monobank_account, now: Time.current)
      item = monobank_account.monobank_item
      zone = item.family.resolved_time_zone
      account = monobank_account.current_account
      cutover = account.provider_cutover_date if account.respond_to?(:provider_cutover_date)

      date = if cutover
        cutover - CUTOVER_OVERLAP
      else
        monobank_account.sync_start_date || item.sync_start_date
      end
      return date.in_time_zone(zone).beginning_of_day if date

      (now.in_time_zone(zone) - initial_history_days.days).beginning_of_day
    end

    def initial_history_days
      Rails.configuration.x.monobank.initial_history_days
    end

    def lookback
      Rails.configuration.x.monobank.pending_lookback_days.days
    end

    def row_time(row)
      value = row.is_a?(Hash) ? (row["time"] || row[:time]) : nil
      value.present? ? Time.zone.at(value.to_i) : nil
    end

    def hold?(row)
      MonobankEntry::Processor.pending?(row)
    end
  end

  attr_reader :monobank_item, :now

  def initialize(monobank_item, now: Time.current)
    @monobank_item = monobank_item
    @now = now
  end

  def next_window
    windows.min_by { |window| sort_key(window) }
  end

  def windows
    eligible_accounts.filter_map { |monobank_account| window_for(monobank_account) }
  end

  # When the earliest product that is backed off after a failed request may be fetched
  # again (it has a window waiting), or nil
  def next_retry_at
    candidates(ignore_backoff: true)
      .select { |monobank_account| monobank_account.next_fetch_after.present? && monobank_account.next_fetch_after > now }
      .select { |monobank_account| window_for(monobank_account) }
      .map(&:next_fetch_after)
      .min
  end

  # Estimated statement requests until every product is up to date
  def windows_remaining
    eligible_accounts.sum { |monobank_account| remaining_for(monobank_account) }
  end

  def target_start(monobank_account)
    self.class.target_start_for(monobank_account, now: now)
  end

  def window_for(monobank_account)
    if monobank_account.page_to.present? && monobank_account.page_from.present?
      kind = monobank_account.page_kind.presence&.to_sym || :forward
      return Window.new(monobank_account, monobank_account.page_from, monobank_account.page_to, kind)
    end

    target = target_start(monobank_account)
    synced_through = monobank_account.statement_synced_through

    if synced_through.nil?
      Window.new(monobank_account, [ target, now - SPAN ].max, now, :first)
    elsif synced_through < now - SPAN
      from = synced_through - self.class.lookback
      Window.new(monobank_account, from, [ from + SPAN, now ].min, :gap)
    elsif forward_needed?(monobank_account)
      from = [ synced_through - self.class.lookback, oldest_hold_time(monobank_account) ].compact.min
      Window.new(monobank_account, [ from, now - SPAN ].max, now, :forward)
    elsif backfill_needed?(monobank_account, target)
      to = monobank_account.history_synced_from
      Window.new(monobank_account, [ target, to - SPAN ].max, to, :backfill)
    end
  end

  def forward_needed?(monobank_account)
    fetched_at = monobank_account.forward_fetched_at
    return true if fetched_at.nil? || fetched_at < now - FORWARD_STALE_AFTER
    return true if !monobank_account.raw_balance_minor.nil? && monobank_account.raw_balance_minor != monobank_account.balance_at_forward_fetch
    return true if oldest_hold_time(monobank_account) && fetched_at < now - HOLD_RECHECK_AFTER

    forced_until = monobank_item.force_forward_until
    forced_until.present? && forced_until > now && fetched_at < forced_until - MonobankItem::FORCE_FORWARD_FOR
  end

  def backfill_needed?(monobank_account, target = target_start(monobank_account))
    !monobank_account.history_complete? &&
      monobank_account.history_synced_from.present? &&
      monobank_account.history_synced_from > target
  end

  def oldest_hold_time(monobank_account)
    Array(monobank_account.raw_transactions_payload)
      .select { |row| self.class.hold?(row) }
      .filter_map { |row| self.class.row_time(row) }
      .min
  end

  private
    def eligible_accounts
      candidates(ignore_backoff: false)
    end

    def candidates(ignore_backoff:)
      return [] if monobank_item.scheduled_for_deletion? || monobank_item.requires_update?

      monobank_item.monobank_accounts.includes(account_provider: :account).select do |monobank_account|
        eligible?(monobank_account, ignore_backoff: ignore_backoff)
      end
    end

    def eligible?(monobank_account, ignore_backoff: false)
      return false if monobank_account.ignored?
      return false if !ignore_backoff && monobank_account.next_fetch_after.present? && monobank_account.next_fetch_after > now

      account = monobank_account.current_account
      account.present? && Account::VISIBLE_STATUSES.include?(account.status)
    end

    def sort_key(window)
      monobank_account = window.monobank_account
      paging = monobank_account.page_to.present? ? 0 : 1
      recency = case window.kind
      when :gap then monobank_account.statement_synced_through.to_f
      when :backfill then -monobank_account.history_synced_from.to_f
      else monobank_account.forward_fetched_at.to_f
      end

      [ PRIORITY.fetch(window.kind, 3), paging, recency, monobank_account.id.to_s ]
    end

    def remaining_for(monobank_account)
      target = target_start(monobank_account)
      synced_through = monobank_account.statement_synced_through
      history_from = monobank_account.history_synced_from
      count = monobank_account.page_to.present? ? 1 : 0

      if synced_through.nil?
        count += 1 if count.zero?
        history_from ||= [ target, now - SPAN ].max
      elsif synced_through < now - SPAN
        count += ((now - synced_through) / SPAN).ceil
      elsif count.zero? && forward_needed?(monobank_account)
        count += 1
      end

      if !monobank_account.history_complete? && history_from.present? && history_from > target
        count += ((history_from - target) / SPAN).ceil
      end

      count
    end
end
