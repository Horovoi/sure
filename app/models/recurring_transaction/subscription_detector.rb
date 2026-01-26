class RecurringTransaction
  class SubscriptionDetector
    class << self
      # Check if a recurring transaction is likely a subscription
      # Only suggests if it matches a known service in the database
      def likely_subscription?(recurring_transaction)
        service_exists_in_database?(recurring_transaction)
      end

      # Check if a matching SubscriptionService exists in the database
      def service_exists_in_database?(recurring_transaction)
        find_matching_service(recurring_transaction).present?
      end

      # Detect and mark subscriptions for a family
      # Creates suggestions with suggestion_status: "suggested" instead of directly marking as subscription
      # Dismissed suggestions stay dismissed (shown in "Previously Dismissed" section)
      # Skips confirmed subscriptions
      def detect_for_family(family)
        # Process all non-subscription records that haven't been suggested yet
        family.recurring_transactions
          .where(is_subscription: false)
          .where(suggestion_status: nil)
          .find_each do |recurring|
            # Skip if subscription already exists for same merchant/name
            next if existing_subscription_for?(family, recurring)

            if likely_subscription?(recurring)
              service = find_matching_service(recurring)

              # Get transaction dates for billing cycle detection
              transaction_dates = get_transaction_dates(recurring)
              billing_cycle = detect_billing_cycle(transaction_dates, amount: recurring.amount)

              updates = {
                suggestion_status: "suggested",
                subscription_service_id: service&.id,
                billing_cycle: billing_cycle
              }

              # For yearly subscriptions, set expected_month and recalculate next_expected_date
              if billing_cycle == :yearly
                expected_month = detect_expected_month(transaction_dates)
                updates[:expected_month] = expected_month

                # Recalculate next_expected_date for yearly cycle (ensure it's in the future)
                updates[:next_expected_date] = calculate_yearly_next_date(
                  recurring.last_occurrence_date,
                  recurring.expected_day_of_month,
                  expected_month
                )
              else
                # For monthly, ensure next_expected_date is in the future
                updates[:next_expected_date] = calculate_monthly_next_date(
                  recurring.last_occurrence_date,
                  recurring.expected_day_of_month
                )
              end

              recurring.update!(updates)
            end
          end
      end

      # Get transaction dates for a recurring transaction
      def get_transaction_dates(recurring)
        entries = RecurringTransaction.find_matching_transaction_entries(
          family: recurring.family,
          merchant_id: recurring.merchant_id,
          name: recurring.name,
          currency: recurring.currency,
          expected_day: recurring.expected_day_of_month,
          lookback_months: 24
        )
        entries.map(&:date)
      end

      # Auto-approve subscriptions that user manually marked
      def auto_approve_for_family(family)
        family.recurring_transactions
          .where(is_subscription: true)
          .where(suggestion_status: "suggested")
          .update_all(suggestion_status: nil)
      end

      # Find matching SubscriptionService by name
      def find_matching_service(recurring)
        name = recurring.merchant&.name || recurring.name
        return nil if name.blank?

        normalized = name.downcase.strip

        # 1. Exact match
        service = SubscriptionService.where("LOWER(name) = ?", normalized).first
        return service if service

        # 2. Service name contains transaction name
        service = SubscriptionService.where("LOWER(name) LIKE ?", "%#{normalized}%").first
        return service if service

        # 3. Transaction name contains full service name (min 4 chars to avoid false positives)
        service = SubscriptionService
          .where("LENGTH(name) >= 4")
          .where("? LIKE '%' || LOWER(name) || '%'", normalized)
          .order("LENGTH(name) DESC")
          .first

        service
      end

      # Detect billing cycle based on transaction history
      # Returns :yearly if gaps between transactions are ~365 days, otherwise :monthly
      # For single transactions, uses elapsed time and price heuristics
      def detect_billing_cycle(transaction_dates, amount: nil)
        return :monthly if transaction_dates.empty?

        # Multiple transactions: use gap analysis
        if transaction_dates.size >= 2
          sorted_dates = transaction_dates.sort
          gaps = sorted_dates.each_cons(2).map { |a, b| (b - a).to_i }
          avg_gap = gaps.sum.to_f / gaps.size
          return avg_gap > 300 ? :yearly : :monthly
        end

        # Single transaction: use elapsed time + price heuristics
        days_elapsed = (Date.current - transaction_dates.first).to_i

        # Strong signal: 90+ days without another charge → yearly
        return :yearly if days_elapsed >= 90

        # Moderate signal: 45-89 days + high price ($40+) → yearly
        return :yearly if days_elapsed >= 45 && amount.present? && amount >= 40

        # Default: monthly (safe assumption)
        :monthly
      end

      # Detect expected month for yearly subscriptions
      # Uses most frequent month, with tie-breaker on most recent transaction
      def detect_expected_month(transaction_dates)
        return nil if transaction_dates.empty?

        sorted_dates = transaction_dates.sort
        month_counts = sorted_dates.map(&:month).tally

        max_count = month_counts.values.max
        top_months = month_counts.select { |_, count| count == max_count }.keys

        if top_months.size == 1
          top_months.first
        else
          # Tie-breaker: use the month of the most recent transaction among top months
          most_recent = sorted_dates.reverse.find { |d| top_months.include?(d.month) }
          most_recent&.month || top_months.first
        end
      end

      # Check if a subscription already exists for the same merchant/name
      # Uses fuzzy matching to handle variations like "iCloud" vs "iCloud+"
      # Does NOT filter by currency because subscriptions can be created in USD
      # while transactions come in local currency (e.g., UAH)
      def existing_subscription_for?(family, recurring)
        name = recurring.merchant&.name || recurring.name
        return false if name.blank?

        normalized = name.downcase.strip

        # Check existing subscriptions using fuzzy name matching (same logic as find_matching_service)
        # No currency filter - a USD subscription should block a UAH duplicate suggestion
        family.recurring_transactions
          .subscriptions
          .joins("LEFT JOIN merchants ON merchants.id = recurring_transactions.merchant_id")
          .where(
            # Match if: subscription display name contains recurring name OR recurring name contains subscription display name
            "LOWER(COALESCE(merchants.name, recurring_transactions.name)) LIKE :pattern " \
            "OR :normalized LIKE '%' || LOWER(COALESCE(merchants.name, recurring_transactions.name)) || '%'",
            pattern: "%#{normalized}%",
            normalized: normalized
          )
          .exists?
      end

      # Calculate next expected date for yearly subscriptions (ensures it's in the future)
      def calculate_yearly_next_date(last_occurrence_date, expected_day, expected_month)
        today = Date.current

        # Start with the year of last occurrence
        target_year = last_occurrence_date.year

        # Build the target date
        loop do
          target_date = begin
            Date.new(target_year, expected_month, expected_day)
          rescue ArgumentError
            # If day doesn't exist in month, use last day of month
            Date.new(target_year, expected_month, 1).end_of_month
          end

          # Return if this date is in the future
          return target_date if target_date > today

          # Otherwise try next year
          target_year += 1
        end
      end

      # Calculate next expected date for monthly subscriptions (ensures it's in the future)
      def calculate_monthly_next_date(last_occurrence_date, expected_day)
        today = Date.current

        # Start from the month after last occurrence
        target_date = last_occurrence_date.next_month

        loop do
          next_date = begin
            Date.new(target_date.year, target_date.month, expected_day)
          rescue ArgumentError
            # If day doesn't exist in month, use last day of month
            target_date.end_of_month
          end

          # Return if this date is in the future
          return next_date if next_date > today

          # Otherwise try next month
          target_date = target_date.next_month
        end
      end
    end
  end
end
