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
      # Re-evaluates dismissed suggestions (they may now match differently with updated algorithm)
      # Skips confirmed subscriptions
      def detect_for_family(family)
        # Reset dismissed suggestions so they can be re-evaluated
        family.recurring_transactions
          .where(is_subscription: false)
          .where(suggestion_status: "dismissed")
          .update_all(suggestion_status: nil, subscription_service_id: nil)

        # Process all non-subscription records that haven't been suggested yet
        family.recurring_transactions
          .where(is_subscription: false)
          .where(suggestion_status: nil)
          .find_each do |recurring|
            if likely_subscription?(recurring)
              service = find_matching_service(recurring)

              # Don't change category here - only set it when user approves
              recurring.update!(
                suggestion_status: "suggested",
                subscription_service_id: service&.id
              )
            end
          end
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
      def detect_billing_cycle(transaction_dates)
        return :monthly if transaction_dates.size < 2

        sorted_dates = transaction_dates.sort
        gaps = sorted_dates.each_cons(2).map { |a, b| (b - a).to_i }

        avg_gap = gaps.sum.to_f / gaps.size

        # If average gap is > 300 days, it's likely yearly
        avg_gap > 300 ? :yearly : :monthly
      end

    end
  end
end
