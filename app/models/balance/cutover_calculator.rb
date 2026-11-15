# Balances of an account a provider took over at a cutover date (Account::ProviderLink),
# after the provider wrote its current balance.
#
# - Before the cutover date the history is the user's: calculated forward from the opening
#   anchor exactly as for a manual account, so those days do not change when linking.
# - From the cutover date on the provider's balance is the truth: calculated backward
#   from the current anchor, counting pending holds when the provider's balance does.
# - On the cutover date the two meet. The day starts at the forward balance of the day
#   before, and any difference between the hand-kept history and the provider (drift) is
#   that day's adjustment, shown once.
class Balance::CutoverCalculator < Balance::BaseCalculator
  def calculate
    Rails.logger.tagged("Balance::CutoverCalculator") do
      cutover = account.provider_cutover_date

      @forward_calculator = Balance::ForwardCalculator.new(account, end_date: cutover - 1.day)
      @reverse_calculator = Balance::ReverseCalculator.new(
        account, stop_date: cutover, include_pending: account.provider_balance_includes_pending?
      )

      join(@forward_calculator.calculate, @reverse_calculator.calculate, cutover)
    end
  end

  def report_unconverted_amounts
    @forward_calculator&.report_unconverted_amounts
    @reverse_calculator&.report_unconverted_amounts
  end

  private
    def join(forward, reverse, cutover)
      forward_end = forward.find { |balance| balance.date == cutover - 1.day }
      cutover_day = reverse.find { |balance| balance.date == cutover }

      if forward_end && cutover_day
        cutover_day.cash_adjustments = cutover_day.start_cash_balance - forward_end.cash_balance
        cutover_day.start_cash_balance = forward_end.cash_balance

        forward_end_non_cash = forward_end.balance - forward_end.cash_balance
        cutover_day.non_cash_adjustments = cutover_day.start_non_cash_balance - forward_end_non_cash
        cutover_day.start_non_cash_balance = forward_end_non_cash
      end

      forward + reverse.sort_by(&:date)
    end
end
