class RecurringTransaction
  class SubscriptionDetector
    # Known subscription service keywords for detection
    KNOWN_SERVICES = %w[
      netflix spotify adobe apple google microsoft hulu disney hbo
      amazon prime dropbox slack notion figma github linear vercel
      openai anthropic chatgpt midjourney gym fitness planet anytime
      youtube twitch patreon substack medium wordpress squarespace
      mailchimp sendgrid aws azure heroku digitalocean cloudflare
      zoom webex teams discord canva grammarly lastpass 1password
      nordvpn expressvpn surfshark audible kindle kindle
      playstation xbox nintendo gamepass crunchyroll funimation
      headspace calm duolingo skillshare masterclass udemy coursera
      peloton strava
    ].freeze

    # Category name that indicates a subscription
    SUBSCRIPTION_CATEGORY_NAME = "Subscriptions".freeze

    class << self
      # Check if a recurring transaction is likely a subscription
      def likely_subscription?(recurring_transaction)
        category_match?(recurring_transaction) ||
          merchant_name_match?(recurring_transaction)
      end

      # Detect and mark subscriptions for a family
      def detect_for_family(family)
        subscriptions_category = find_subscriptions_category(family)

        family.recurring_transactions.where(is_subscription: false).find_each do |recurring|
          if likely_subscription?(recurring)
            service = find_matching_service(recurring)

            recurring.update!(
              is_subscription: true,
              category_id: subscriptions_category&.id,
              subscription_service_id: service&.id
            )

            if service.present? && !service.icon.attached?
              CacheSubscriptionIconJob.perform_later(service)
            end
          end
        end
      end

      # Find matching SubscriptionService by name
      def find_matching_service(recurring)
        name = recurring.merchant&.name || recurring.name
        return nil if name.blank?

        normalized = name.downcase.strip

        # 1. Exact match
        service = SubscriptionService.where("LOWER(name) = ?", normalized).first
        return service if service

        # 2. Service name contains subscription name
        service = SubscriptionService.where("LOWER(name) LIKE ?", "%#{normalized}%").first
        return service if service

        # 3. Subscription name contains service name
        service = SubscriptionService.where("? LIKE '%' || LOWER(name) || '%'", normalized).first
        return service if service

        # 4. Word-based matching
        words = normalized.split(/\s+/).reject { |w| w.length < 3 }
        words.each do |word|
          service = SubscriptionService.where("LOWER(name) LIKE ?", "#{word}%").first
          return service if service
        end

        nil
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

      private

        def category_match?(recurring_transaction)
          category = recurring_transaction.category
          return false if category.nil?

          category.name.downcase.include?("subscription")
        end

        def merchant_name_match?(recurring_transaction)
          name = recurring_transaction.merchant&.name || recurring_transaction.name
          return false if name.blank?

          name_lower = name.downcase

          KNOWN_SERVICES.any? { |service| name_lower.include?(service) }
        end

        def find_subscriptions_category(family)
          family.categories.find_by("LOWER(name) LIKE ?", "%subscription%")
        end
    end
  end
end
