class RecurringTransaction
  class BaseCurrencyDetector
    # Variance threshold - if amount variance exceeds this, suspect currency conversion
    VARIANCE_THRESHOLD = 0.01  # 1%

    # Cluster threshold - target amounts must cluster within this to be valid
    CLUSTER_THRESHOLD = 0.02  # 2%

    # Nice price tolerance - how close to a "nice" number ($X.99, $X.00, $X.49)
    NICE_PRICE_TOLERANCE = 0.15  # 15 cents

    attr_reader :entries, :account_currency

    def initialize(entries:, account_currency:)
      @entries = entries
      @account_currency = account_currency
    end

    # Detect if the recurring pattern is likely priced in a different currency
    # - UAH accounts → detect USD base price
    # - USD accounts → detect UAH base price
    # Returns { currency: "USD", amount: 9.99 } or nil if not detected
    def detect
      return nil if should_skip?
      return nil unless high_variance?

      target_currency = determine_target_currency
      return nil unless target_currency

      converted_amounts = convert_to_currency(target_currency)
      return nil if converted_amounts.empty?

      clustered_amount = find_clustered_amount(converted_amounts)
      return nil unless clustered_amount

      nice_amount = find_nice_amount(clustered_amount, target_currency)
      return nil unless nice_amount

      { currency: target_currency, amount: nice_amount }
    end

    private

      # Determine what currency to convert to based on account currency
      def determine_target_currency
        case account_currency
        when "UAH" then "USD"
        when "USD" then "UAH"
        else "USD"  # Default: try to detect USD pricing for other currencies
        end
      end

      # Skip if account currency doesn't support conversion
      def should_skip?
        # Support UAH ↔ USD conversion, and non-USD → USD
        false
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

      # Convert each entry amount to target currency using historical exchange rates
      def convert_to_currency(target_currency)
        entries.filter_map do |entry|
          rate_record = ExchangeRate.find_or_fetch_rate(
            from: target_currency,
            to: entry.currency,
            date: entry.date
          )

          next nil unless rate_record

          rate = rate_record.rate
          next nil if rate.zero?

          # entry.amount is in local currency, divide by rate to get target currency
          (entry.amount / rate).round(2)
        end
      end

      # Check if converted amounts cluster within 2% and return the cluster center
      def find_clustered_amount(converted_amounts)
        return nil if converted_amounts.size < 2

        avg = converted_amounts.sum / converted_amounts.size
        return nil if avg.zero?

        # Check all amounts are within cluster threshold of average
        all_within_cluster = converted_amounts.all? do |amount|
          ((amount - avg) / avg).abs <= CLUSTER_THRESHOLD
        end

        return nil unless all_within_cluster

        avg
      end

      # Find nearest "nice" amount based on currency conventions
      # USD: $X.99, $X.49, $X.00 (common subscription pricing)
      # UAH: round numbers (10, 50, 100, 150, 200, etc.)
      # Returns the nice amount if within tolerance, otherwise nil
      def find_nice_amount(clustered_amount, target_currency)
        if target_currency == "UAH"
          find_nice_uah_amount(clustered_amount)
        else
          find_nice_usd_amount(clustered_amount)
        end
      end

      def find_nice_usd_amount(clustered_amount)
        base = clustered_amount.floor

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

      def find_nice_uah_amount(clustered_amount)
        # UAH typically uses round numbers
        # Common endings: 0, 50 (e.g., 100, 150, 200, 250, 500, 1000)
        rounded = clustered_amount.round

        # Check if it's close to a round number (within 5 UAH tolerance)
        uah_tolerance = 5.0

        # Try multiples of 10 and 50
        candidates = [
          (clustered_amount / 10.0).round * 10,   # Nearest 10
          (clustered_amount / 50.0).round * 50,   # Nearest 50
          (clustered_amount / 100.0).round * 100  # Nearest 100
        ]

        candidates.each do |nice|
          if (clustered_amount - nice).abs <= uah_tolerance
            return nice
          end
        end

        # If close to any integer, use that
        if (clustered_amount - rounded).abs <= 1.0
          return rounded
        end

        nil
      end
  end
end
