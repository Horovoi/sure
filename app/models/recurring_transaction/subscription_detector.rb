class RecurringTransaction
  class SubscriptionDetector
    # A transaction name names a service when it contains the service's full
    # name. Shorter names would match by accident ("TV", "App").
    MIN_SERVICE_NAME_LENGTH = 4

    class << self
      # The form names are compared in: lower case, no surrounding spaces
      def normalize_service_name(name)
        name.to_s.downcase.strip
      end

      # Whether a transaction or merchant name contains the full service (or
      # subscription display) name. The rule of find_matching_service's last
      # step; the subscription reconciler uses it to tell a real charge of the
      # same service.
      def name_contains_service_name?(name, service_name)
        normalized_service = normalize_service_name(service_name)
        return false if normalized_service.length < MIN_SERVICE_NAME_LENGTH

        normalize_service_name(name).include?(normalized_service)
      end

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
      # Moves plain patterns to "suggested" instead of directly marking them as subscriptions
      # Dismissed suggestions stay dismissed (shown in "Previously Dismissed" section)
      # Skips confirmed subscriptions
      def detect_for_family(family)
        # Process plain patterns only: not suggested, dismissed or confirmed yet
        family.recurring_transactions
          .pattern
          .find_each do |recurring|
            # Skip if subscription already exists for same merchant/name
            next if existing_subscription_for?(family, recurring)

            # A dismissal covers the merchant or name, whatever its amount
            next if dismissed_for?(family, recurring)

            if likely_subscription?(recurring)
              service = find_matching_service(recurring)

              # Get transaction dates for billing cycle detection
              transaction_dates = get_transaction_dates(recurring)
              billing_cycle = detect_billing_cycle(transaction_dates, amount: recurring.amount)

              updates = {
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

              recurring.assign_attributes(updates)
              recurring.suggest!
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

      # Find matching SubscriptionService by name
      def find_matching_service(recurring)
        name = recurring.merchant&.name || recurring.name
        return nil if name.blank?

        normalized = normalize_service_name(name)

        # 1. Exact match
        service = SubscriptionService.where("LOWER(name) = ?", normalized).first
        return service if service

        # 2. Service name contains transaction name
        service = SubscriptionService.where("LOWER(name) LIKE ?", "%#{normalized}%").first
        return service if service

        # 3. Transaction name contains full service name (name_contains_service_name? in SQL)
        service = SubscriptionService
          .where("LENGTH(name) >= ?", MIN_SERVICE_NAME_LENGTH)
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

      # Whether the user dismissed a suggestion for the same merchant or name
      def dismissed_for?(family, recurring)
        scope = family.recurring_transactions.dismissed.where.not(id: recurring.id)
        if recurring.merchant_id.present?
          scope.where(merchant_id: recurring.merchant_id).exists?
        else
          scope.where(merchant_id: nil, name: recurring.name).exists?
        end
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
