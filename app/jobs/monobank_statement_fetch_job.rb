# One link of a connection's statement fetch chain: at most one monobank request per
# run, then the job schedules itself for the next free request slot.
#
# The chain belongs to the token stored on the item (fetch_chain_token); a job with an
# older token exits, so a lost job is simply replaced by the next sync. A job that finds
# the connection refused, being deleted or monobank switched off ends its chain, so a
# new one can start at once. Rows are only stored here; every PROCESS_EVERY_WINDOWS
# completed windows, and when nothing is left to fetch, the job asks for an item sync,
# which turns them into entries.
class MonobankStatementFetchJob < ApplicationJob
  queue_as :medium_priority

  PROCESS_EVERY_WINDOWS = 5
  # How long the chain waits for a product in a short backoff before leaving it to the
  # next hourly sync
  MAX_WAIT = 30.minutes
  # While it waits, the chain looks again this often (in request slots), so a "Sync now"
  # or a balance change of another product is fetched soon
  PARK_RECHECK_SLOTS = 2

  discard_on ActiveJob::DeserializationError

  def perform(monobank_item, chain_token, completed_windows = 0, parked = false)
    return unless chain_owner?(monobank_item, chain_token)

    provider = monobank_item.monobank_provider
    return finish_chain(monobank_item, chain_token) if provider.nil?

    plan = MonobankItem::FetchPlan.new(monobank_item)
    window = plan.next_window
    if window.nil?
      # A product that failed soon comes back from its backoff: book what is here and
      # wait for it, looking again every few slots. A longer backoff is left to the next
      # hourly sync.
      retry_at = plan.next_retry_at
      if retry_at && retry_at <= Time.current + MAX_WAIT
        monobank_item.sync_later unless parked
        recheck_at = Time.current + PARK_RECHECK_SLOTS * provider.min_request_interval.seconds
        return reschedule(monobank_item, chain_token, completed_windows, at: [ retry_at + 1.second, recheck_at ].min, parked: true)
      end

      return finish_chain(monobank_item, chain_token)
    end

    importer = MonobankItem::Importer.new(monobank_item, provider: provider)

    begin
      rows = provider.get_statement(account_id: window.monobank_account.account_id, from: window.from, to: window.to)
      if importer.store_window!(window, rows) == :complete
        completed_windows += 1
        monobank_item.sync_later if (completed_windows % PROCESS_EVERY_WINDOWS).zero?
      end
    rescue Provider::Monobank::RateLimitError => e
      return reschedule(monobank_item, chain_token, completed_windows, at: (e.retry_at || Time.current) + 1.second)
    rescue Provider::Monobank::Error => e
      if importer.auth_failure?(e)
        importer.mark_requires_update!
        monobank_item.capture_error("monobank refused the token; statement fetch stopped", e, monobank_account: window.monobank_account)
        monobank_item.end_fetch_chain!(chain_token)
        return
      elsif e.failure_code == :bad_request && window.kind == :backfill
        importer.record_history_limit!(window.monobank_account, window, e)
      else
        importer.record_fetch_failure!(window.monobank_account, e)
      end
    end

    reschedule(monobank_item, chain_token, completed_windows, at: provider.next_request_slot_at(:statement) + 1.second)
  end

  private
    def chain_owner?(monobank_item, chain_token)
      monobank_item.reload
      return false unless monobank_item.fetch_chain_token.present? && monobank_item.fetch_chain_token == chain_token

      if monobank_item.scheduled_for_deletion? || monobank_item.requires_update? || !BankConnections.enabled?(:monobank)
        monobank_item.end_fetch_chain!(chain_token)
        return false
      end

      true
    end

    def finish_chain(monobank_item, chain_token)
      monobank_item.end_fetch_chain!(chain_token)
      monobank_item.sync_later
    end

    def reschedule(monobank_item, chain_token, completed_windows, at:, parked: false)
      at = [ at, Time.current + 1.second ].max
      monobank_item.update_columns(fetch_chain_heartbeat_at: at)
      args = [ monobank_item, chain_token, completed_windows ]
      args << true if parked
      self.class.set(wait_until: at).perform_later(*args)
    end
end
