# One link of a connection's statement fetch chain: at most one monobank request per
# run, then the job schedules itself for the next free request slot.
#
# The chain belongs to the token stored on the item (fetch_chain_token); a job with an
# older token exits, so a lost job is simply replaced by the next sync. Rows are only
# stored here; every PROCESS_EVERY_WINDOWS completed windows, and when nothing is left
# to fetch, the job asks for an item sync, which turns them into entries.
class MonobankStatementFetchJob < ApplicationJob
  queue_as :medium_priority

  PROCESS_EVERY_WINDOWS = 5

  discard_on ActiveJob::DeserializationError

  def perform(monobank_item, chain_token, completed_windows = 0)
    return unless chain_owner?(monobank_item, chain_token)

    provider = monobank_item.monobank_provider
    window = MonobankItem::FetchPlan.new(monobank_item).next_window
    return finish_chain(monobank_item, chain_token) if provider.nil? || window.nil?

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
      return false if monobank_item.scheduled_for_deletion? || monobank_item.requires_update?

      monobank_item.fetch_chain_token.present? && monobank_item.fetch_chain_token == chain_token
    end

    def finish_chain(monobank_item, chain_token)
      monobank_item.end_fetch_chain!(chain_token)
      monobank_item.sync_later
    end

    def reschedule(monobank_item, chain_token, completed_windows, at:)
      at = [ at, Time.current + 1.second ].max
      monobank_item.update_columns(fetch_chain_heartbeat_at: at)
      self.class.set(wait_until: at).perform_later(monobank_item, chain_token, completed_windows)
    end
end
