# Remembers the provider's answer for a currency pair and date for the rest of
# the current request or background job, including "no rate available".
#
# A page that converts many amounts (subscriptions, report rows) asks for the same
# pair and date once per row. Without this, a rate that is not stored yet costs
# one provider HTTP round-trip per row; with it, one per pair and date.
#
# Rails resets CurrentAttributes between requests and jobs, so nothing stale
# survives into the next unit of work.
class ExchangeRate::FetchMemo < ActiveSupport::CurrentAttributes
  attribute :results

  def fetch(key)
    self.results ||= {}
    return results[key] if results.key?(key)

    results[key] = yield
  end
end
