class RecurringTransaction
  class Identifier
    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Amount tolerance for grouping (15% to handle exchange rate fluctuations)
    AMOUNT_TOLERANCE = 0.15

    # Identify and create/update recurring transactions for the family
    def identify_recurring_patterns
      three_months_ago = 3.months.ago.to_date

      # Get all transactions from the last 3 months
      entries_with_transactions = family.entries
        .where(entryable_type: "Transaction")
        .where("entries.date >= ?", three_months_ago)
        .includes(:entryable, :account)
        .to_a

      # Group by merchant (if present) or name, along with normalized amount bucket and account currency
      # This handles multi-currency scenarios (e.g., USD subscriptions from UAH accounts)
      grouped_transactions = entries_with_transactions
        .select { |entry| entry.entryable.is_a?(Transaction) }
        .group_by do |entry|
          transaction = entry.entryable
          # Use merchant_id if present, otherwise use entry name
          identifier = transaction.merchant_id.present? ? [ :merchant, transaction.merchant_id ] : [ :name, entry.name ]

          # Normalize amount to account currency for consistent grouping
          normalized = normalized_amount(entry)
          next nil unless normalized  # Skip entries without exchange rate data

          # Create amount bucket for tolerance-based grouping
          bucket = amount_bucket(normalized, tolerance: AMOUNT_TOLERANCE)
          [ identifier, bucket, entry.account.currency ]
        end.compact

      recurring_patterns = []

      grouped_transactions.each do |(identifier, amount_bucket, currency), entries|
        next if identifier.nil?  # Skip nil keys from failed normalization
        next if entries.size < 3  # Must have at least 3 occurrences

        # Check if the last occurrence was within the last 45 days
        last_occurrence = entries.max_by(&:date)
        next if last_occurrence.date < 45.days.ago.to_date

        # Check if transactions occur on similar days (within 5 days of each other)
        days_of_month = entries.map { |e| e.date.day }.sort

        # Calculate if days cluster together (standard deviation check)
        if days_cluster_together?(days_of_month)
          expected_day = calculate_expected_day(days_of_month)

          # Unpack identifier - either [:merchant, id] or [:name, name_string]
          identifier_type, identifier_value = identifier

          # Calculate average normalized amount for the pattern (more accurate than bucket)
          normalized_amounts = entries.map { |e| normalized_amount(e) }.compact
          avg_amount = (normalized_amounts.sum / normalized_amounts.size).round(2)

          # Determine inferred account (most frequent account in pattern)
          account_counts = entries.map { |e| e.account_id }.tally
          inferred_account_id = account_counts.max_by { |_, count| count }&.first

          # Detect if pattern might be priced in USD (for non-USD accounts)
          base_currency_result = BaseCurrencyDetector.new(
            entries: entries,
            account_currency: currency
          ).detect

          pattern = {
            amount: avg_amount,
            currency: currency,
            expected_day_of_month: expected_day,
            last_occurrence_date: last_occurrence.date,
            occurrence_count: entries.size,
            entries: entries,
            inferred_account_id: inferred_account_id,
            detected_base_currency: base_currency_result&.dig(:currency),
            detected_base_amount: base_currency_result&.dig(:amount)
          }

          if identifier_type == :merchant
            pattern[:merchant_id] = identifier_value
          else
            pattern[:name] = identifier_value
          end

          recurring_patterns << pattern
        end
      end

      # Create or update RecurringTransaction records.
      # Identity is (merchant or name, currency). The amount is not part of
      # it: an existing row matches when its amount is within the tolerance
      # of the pattern's average, which drifts with FX rates and prices.
      claimed_ids = []
      recurring_patterns.each do |pattern|
        begin
          recurring_transaction = find_existing(pattern, excluding: claimed_ids)

          if recurring_transaction
            claimed_ids << recurring_transaction.id

            if recurring_transaction.manual?
              update_manual_recurring_variance(recurring_transaction, pattern)
            else
              refresh_existing(recurring_transaction, pattern)
            end
          else
            create_from_pattern(pattern)
          end
        rescue ActiveRecord::RecordNotUnique
          # A concurrent run wrote the same row; the next run refreshes it.
          next
        end
      end

      # Also check for manual recurring transactions that might need variance updates
      update_manual_recurring_transactions(three_months_ago)

      # Detect subscriptions for newly created recurring transactions
      RecurringTransaction::SubscriptionDetector.detect_for_family(family)

      recurring_patterns.size
    end

    # Existing row with the pattern's identity whose amount is within the
    # tolerance; the closest one when several match.
    def find_existing(pattern, excluding: [])
      candidates = family.recurring_transactions
        .with_identity(merchant_id: pattern[:merchant_id], name: pattern[:name], currency: pattern[:currency])
        .where.not(id: excluding)
        .to_a

      candidates
        .select { |recurring| amount_matches?(recurring, pattern[:amount]) }
        .min_by { |recurring| [ (recurring.amount - pattern[:amount]).abs, recurring.subscription? ? 0 : 1 ] }
    end

    # Update variance for existing manual recurring transactions
    def update_manual_recurring_transactions(since_date)
      family.recurring_transactions.where(manual: true, status: "active").find_each do |recurring|
        # Find matching transactions in the recent period
        matching_entries = RecurringTransaction.find_matching_transaction_entries(
          family: family,
          merchant_id: recurring.merchant_id,
          name: recurring.name,
          currency: recurring.currency,
          expected_day: recurring.expected_day_of_month,
          lookback_months: 6
        )

        next if matching_entries.empty?

        # Extract amounts and dates from all matching entries
        matching_amounts = matching_entries.map(&:amount)
        last_entry = matching_entries.max_by(&:date)

        # Recalculate variance from all occurrences (including identical amounts).
        # next_expected_date only moves forward: moving it back would make an
        # already-handled period overdue again.
        recurring.update!(
          expected_amount_min: matching_amounts.min,
          expected_amount_max: matching_amounts.max,
          expected_amount_avg: matching_amounts.sum / matching_amounts.size,
          occurrence_count: matching_amounts.size,
          last_occurrence_date: [ recurring.last_occurrence_date, last_entry.date ].compact.max,
          next_expected_date: forward_only(recurring.next_expected_date, calculate_next_expected_date(last_entry.date, recurring.expected_day_of_month))
        )
      end
    end

    # Update variance for a manual recurring transaction when pattern is found
    def update_manual_recurring_variance(recurring_transaction, pattern)
      # Check if this transaction's date is more recent
      if pattern[:last_occurrence_date] > recurring_transaction.last_occurrence_date
        # Find all matching transactions to recalculate variance
        matching_entries = RecurringTransaction.find_matching_transaction_entries(
          family: family,
          merchant_id: recurring_transaction.merchant_id,
          name: recurring_transaction.name,
          currency: recurring_transaction.currency,
          expected_day: recurring_transaction.expected_day_of_month,
          lookback_months: 6
        )

        # Update if we have any matching transactions
        if matching_entries.any?
          matching_amounts = matching_entries.map(&:amount)

          recurring_transaction.update!(
            expected_amount_min: matching_amounts.min,
            expected_amount_max: matching_amounts.max,
            expected_amount_avg: matching_amounts.sum / matching_amounts.size,
            occurrence_count: matching_amounts.size,
            last_occurrence_date: pattern[:last_occurrence_date],
            next_expected_date: forward_only(recurring_transaction.next_expected_date, calculate_next_expected_date(pattern[:last_occurrence_date], recurring_transaction.expected_day_of_month))
          )
        end
      end
    end

    private
      def amount_matches?(recurring, amount)
        reference = recurring.amount
        tolerance = [ reference.abs, amount.abs ].max * AMOUNT_TOLERANCE
        return true if (reference - amount).abs <= tolerance

        # Manual rows track a range of observed amounts
        recurring.has_amount_variance? &&
          amount.between?(recurring.expected_amount_min - tolerance, recurring.expected_amount_max + tolerance)
      end

      def forward_only(current, candidate)
        [ current, candidate ].compact.max
      end

      # Stale rows come back when the pattern resumes. A row the user paused
      # stays inactive. Legacy rows without a reason come back only when they
      # are plain detected patterns.
      def reactivatable?(recurring)
        return false unless recurring.inactive?

        recurring.inactive_reason == "stale" || (recurring.inactive_reason.nil? && !recurring.user_managed?)
      end

      def create_from_pattern(pattern)
        recurring = family.recurring_transactions.new(
          merchant_id: pattern[:merchant_id],
          name: pattern[:merchant_id].present? ? nil : pattern[:name],
          amount: pattern[:amount],
          currency: pattern[:currency],
          manual: false,
          status: "active",
          expected_day_of_month: pattern[:expected_day_of_month],
          last_occurrence_date: pattern[:last_occurrence_date],
          next_expected_date: calculate_next_expected_date(pattern[:last_occurrence_date], pattern[:expected_day_of_month]),
          occurrence_count: pattern[:occurrence_count],
          inferred_account_id: pattern[:inferred_account_id],
          detected_base_currency: pattern[:detected_base_currency],
          detected_base_amount: pattern[:detected_base_amount]
        )
        # Detected patterns do not generate transactions, so their projected
        # date is always the next one after today.
        recurring.roll_next_expected_date_forward
        recurring.save!
      end

      def refresh_existing(recurring, pattern)
        if recurring.subscription?
          refresh_subscription(recurring, pattern)
        else
          refresh_detected(recurring, pattern)
        end

        if reactivatable?(recurring)
          recurring.status = "active"
          recurring.inactive_reason = nil
        end

        recurring.save!
      end

      # Plain patterns, suggestions and dismissed suggestions follow the data.
      def refresh_detected(recurring, pattern)
        recurring.assign_attributes(
          amount: pattern[:amount],
          expected_day_of_month: pattern[:expected_day_of_month],
          last_occurrence_date: pattern[:last_occurrence_date],
          next_expected_date: calculate_next_expected_date(pattern[:last_occurrence_date], pattern[:expected_day_of_month]),
          occurrence_count: pattern[:occurrence_count],
          inferred_account_id: pattern[:inferred_account_id],
          detected_base_currency: pattern[:detected_base_currency],
          detected_base_amount: pattern[:detected_base_amount]
        )
        recurring.roll_next_expected_date_forward
      end

      # Approved subscriptions keep what the user set (amount, billing day,
      # cycle). Only a newer occurrence moves the dates, and only forward,
      # so an overdue period is never skipped.
      def refresh_subscription(recurring, pattern)
        recurring.assign_attributes(
          inferred_account_id: pattern[:inferred_account_id],
          detected_base_currency: pattern[:detected_base_currency],
          detected_base_amount: pattern[:detected_base_amount]
        )

        last_date = pattern[:last_occurrence_date]
        return unless recurring.last_occurrence_date.nil? || last_date > recurring.last_occurrence_date

        recurring.last_occurrence_date = last_date
        recurring.next_expected_date = forward_only(recurring.next_expected_date, recurring.calculate_next_expected_date(last_date))
      end

      # Check if days cluster together (within ~5 days variance)
      # Uses circular distance to handle month-boundary wrapping (e.g., 28, 29, 30, 31, 1, 2)
      def days_cluster_together?(days)
        return false if days.empty?

        # Calculate median as reference point
        median = calculate_expected_day(days)

        # Calculate circular distances from median
        circular_distances = days.map { |day| circular_distance(day, median) }

        # Calculate standard deviation of circular distances
        mean_distance = circular_distances.sum.to_f / circular_distances.size
        variance = circular_distances.map { |dist| (dist - mean_distance)**2 }.sum / circular_distances.size
        std_dev = Math.sqrt(variance)

        # Allow up to 5 days standard deviation
        std_dev <= 5
      end

      # Calculate circular distance between two days on a 31-day circle
      # Examples:
      #   circular_distance(1, 31) = 2  (wraps around: 31 -> 1 is 1 day forward)
      #   circular_distance(28, 2) = 5  (wraps: 28, 29, 30, 31, 1, 2)
      def circular_distance(day1, day2)
        linear_distance = (day1 - day2).abs
        wrap_distance = 31 - linear_distance
        [ linear_distance, wrap_distance ].min
      end

      # Calculate the expected day based on the most common day
      # Uses circular rotation to handle month-wrapping sequences (e.g., [29, 30, 31, 1, 2])
      def calculate_expected_day(days)
        return days.first if days.size == 1

        # Convert to 0-indexed (0-30 instead of 1-31) for modular arithmetic
        days_0 = days.map { |d| d - 1 }

        # Find the rotation (pivot) that minimizes span, making the cluster contiguous
        # This handles month-wrapping sequences like [29, 30, 31, 1, 2]
        best_pivot = 0
        min_span = Float::INFINITY

        (0..30).each do |pivot|
          rotated = days_0.map { |d| (d - pivot) % 31 }
          span = rotated.max - rotated.min

          if span < min_span
            min_span = span
            best_pivot = pivot
          end
        end

        # Rotate days using best pivot to create contiguous array
        rotated_days = days_0.map { |d| (d - best_pivot) % 31 }.sort

        # Calculate median on rotated, contiguous array
        mid = rotated_days.size / 2
        rotated_median = if rotated_days.size.odd?
          rotated_days[mid]
        else
          # For even count, average and round
          ((rotated_days[mid - 1] + rotated_days[mid]) / 2.0).round
        end

        # Map median back to original day space (unrotate) and convert to 1-indexed
        original_day = (rotated_median + best_pivot) % 31 + 1

        original_day
      end

      # Calculate next expected date
      def calculate_next_expected_date(last_date, expected_day)
        next_month = last_date.next_month

        begin
          Date.new(next_month.year, next_month.month, expected_day)
        rescue ArgumentError
          # If day doesn't exist in month, use last day of month
          next_month.end_of_month
        end
      end

      # Normalize entry amount to account currency for consistent grouping
      # This handles multi-currency scenarios (e.g., USD subscription from UAH account)
      def normalized_amount(entry)
        # If entry currency matches account currency, no conversion needed
        return entry.amount if entry.currency == entry.account.currency

        # Fetch exchange rate for the transaction date
        rate_record = ExchangeRate.find_or_fetch_rate(
          from: entry.currency,
          to: entry.account.currency,
          date: entry.date
        )

        return nil unless rate_record  # Skip if no rate available

        rate = rate_record.is_a?(ExchangeRate) ? rate_record.rate : rate_record.rate
        (entry.amount * rate).round(2)
      end

      # Create amount bucket for tolerance-based grouping
      # Similar amounts within tolerance are grouped together
      def amount_bucket(amount, tolerance: AMOUNT_TOLERANCE)
        return 0 if amount.zero?

        # Use logarithmic buckets so $10±15% and $100±15% scale appropriately
        # The bucket size scales with the magnitude of the amount
        magnitude = 10 ** Math.log10(amount.abs).floor
        bucket_size = magnitude * tolerance * 2

        # Round to nearest bucket
        ((amount / bucket_size).round * bucket_size).round(2)
      end
  end
end
