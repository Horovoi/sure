class GenerateSubscriptionTransactionsJob < ApplicationJob
  queue_as :scheduled

  # Generates transactions for due subscriptions across all families
  # Only processes subscriptions where:
  # - next_expected_date <= today
  # - RecurringTransaction#can_auto_generate? (an active account with no
  #   provider connection)
  def perform
    stats = { families_processed: 0, subscriptions_processed: 0, transactions_created: 0 }

    Family.find_each do |family|
      result = generate_for_family(family)
      stats[:families_processed] += 1
      stats[:subscriptions_processed] += result[:subscriptions_processed]
      stats[:transactions_created] += result[:transactions_created]
    end

    Rails.logger.info(
      "GenerateSubscriptionTransactionsJob completed: " \
      "#{stats[:families_processed]} families, " \
      "#{stats[:subscriptions_processed]} subscriptions processed, " \
      "#{stats[:transactions_created]} transactions created"
    )

    stats
  end

  private

    def generate_for_family(family)
      result = { subscriptions_processed: 0, transactions_created: 0 }

      due_subscriptions(family).find_each do |subscription|
        next unless subscription.can_auto_generate?

        begin
          entries = subscription.generate_overdue_transactions!
          result[:subscriptions_processed] += 1
          result[:transactions_created] += entries.size

          if entries.any?
            Rails.logger.info(
              "Generated #{entries.size} transaction(s) for subscription '#{subscription.display_name}' " \
              "(family: #{family.id})"
            )
          end
        rescue StandardError => e
          Rails.logger.error(
            "Failed to generate transactions for subscription #{subscription.id}: #{e.message}"
          )
        end
      end

      result
    end

    def due_subscriptions(family)
      family.recurring_transactions
        .active_subscriptions
        .where("next_expected_date <= ?", Date.current)
        .where.not(default_account_id: nil)
        .includes(:default_account)
    end
end
