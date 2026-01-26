class RecurringTransaction
  class BaseCurrencyDetector
    # Variance threshold - if amount variance exceeds this, suspect currency conversion
    VARIANCE_THRESHOLD = 0.01  # 1%

    # Cluster threshold - USD amounts must cluster within this to be valid
    CLUSTER_THRESHOLD = 0.02  # 2%

    # Nice price tolerance - how close to a "nice" number ($X.99, $X.00, $X.49)
    NICE_PRICE_TOLERANCE = 0.15  # 15 cents

    # Target currency for detection
    TARGET_CURRENCY = "USD"

    attr_reader :entries, :account_currency

    def initialize(entries:, account_currency:)
      @entries = entries
      @account_currency = account_currency
    end

    # Detect if the recurring pattern is likely priced in USD
    # Returns { currency: "USD", amount: 9.99 } or nil if not detected
    def detect
      return nil if should_skip?
      return nil unless high_variance?

      usd_amounts = convert_to_usd
      return nil if usd_amounts.empty?

      clustered_amount = find_clustered_amount(usd_amounts)
      return nil unless clustered_amount

      nice_amount = find_nice_amount(clustered_amount)
      return nil unless nice_amount

      { currency: TARGET_CURRENCY, amount: nice_amount }
    end

    private

      # Skip if account is already in USD
      def should_skip?
        account_currency == TARGET_CURRENCY
      end

      # Check if amounts have high variance (>5%)
      def high_variance?
        amounts = entries.map(&:amount)
        return false if amounts.size < 2

        avg = amounts.sum / amounts.size
        return false if avg.zero?

        variance = amounts.map { |a| ((a - avg) / avg).abs }.max
        variance > VARIANCE_THRESHOLD
      end

      # Convert each entry amount back to USD using historical exchange rates
      def convert_to_usd
        entries.filter_map do |entry|
          rate_record = ExchangeRate.find_or_fetch_rate(
            from: TARGET_CURRENCY,
            to: entry.currency,
            date: entry.date
          )

          next nil unless rate_record

          rate = rate_record.rate
          next nil if rate.zero?

          # entry.amount is in local currency, divide by rate to get USD
          (entry.amount / rate).round(2)
        end
      end

      # Check if USD amounts cluster within 2% and return the cluster center
      def find_clustered_amount(usd_amounts)
        return nil if usd_amounts.size < 2

        avg = usd_amounts.sum / usd_amounts.size
        return nil if avg.zero?

        # Check all amounts are within cluster threshold of average
        all_within_cluster = usd_amounts.all? do |amount|
          ((amount - avg) / avg).abs <= CLUSTER_THRESHOLD
        end

        return nil unless all_within_cluster

        avg
      end

      # Find nearest "nice" amount ($X.99, $X.49, $X.00)
      # Returns the nice amount if within tolerance, otherwise nil
      def find_nice_amount(clustered_amount)
        base = clustered_amount.floor
        cents = clustered_amount - base

        nice_endings = [ 0.99, 0.49, 0.00 ]

        nice_endings.each do |ending|
          candidate = base + ending
          # Also try one dollar higher for .99 and .49 since floor might be wrong
          candidates = [ candidate ]
          candidates << (base + 1 + ending) if ending < 0.5

          candidates.each do |nice|
            if (clustered_amount - nice).abs <= NICE_PRICE_TOLERANCE
              return nice
            end
          end
        end

        nil
      end
  end
end
