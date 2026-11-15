class SubscriptionsController < ApplicationController
  # ?kind= value of the Other recurring tab
  OTHER_RECURRING_KIND = "other"

  before_action :set_subscription, only: %i[show edit update record_transaction skip_occurrence]
  before_action :set_recurring_row, only: %i[destroy toggle_status make_subscription]
  before_action :set_suggestion, only: %i[approve_suggestion dismiss_suggestion]
  before_action :set_dismissed_suggestion, only: %i[restore_suggestion]

  def index
    # kind=other lists the manual recurring rows that are not subscriptions
    @other_recurring = params[:kind] == OTHER_RECURRING_KIND
    rows = Current.family.recurring_transactions
    @subscriptions = (@other_recurring ? rows.other_recurring : rows.subscriptions)
                          .includes(:merchant, :category, :subscription_service, :default_account)
                          .with_attached_logo
                          .order(status: :asc, next_expected_date: :asc, name: :asc)

    # Apply filters
    @subscriptions = @subscriptions.active if params[:status] == "active"
    @subscriptions = @subscriptions.inactive if params[:status] == "inactive"
    if params[:billing_cycle].present? && !@other_recurring
      @subscriptions = @subscriptions.where(billing_cycle: params[:billing_cycle])
    end

    if params[:search].present?
      search_term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search].downcase)}%"
      @subscriptions = @subscriptions.joins("LEFT JOIN merchants ON merchants.id = recurring_transactions.merchant_id")
                                     .where("LOWER(recurring_transactions.name) LIKE ? OR LOWER(merchants.name) LIKE ?",
                                            search_term, search_term)
    end

    # Counts for subheader (before any filtering for accurate totals)
    all_subscriptions = Current.family.recurring_transactions.subscriptions
    @active_count = all_subscriptions.active.count
    @inactive_count = all_subscriptions.inactive.count
    @suggestion_count = Current.family.recurring_transactions.suggested.count
    @other_recurring_count = rows.other_recurring.count

    # The header always sums subscriptions, also on the Other recurring tab
    totals_source = @other_recurring ? all_subscriptions.active.to_a : @subscriptions
    @monthly_total = calculate_monthly_total(totals_source)
    @yearly_total = calculate_yearly_total(totals_source)
    @breadcrumbs = [ [ t(".home"), root_path ], [ t(".title"), nil ] ]

    respond_to do |format|
      format.html do
        if turbo_frame_request?
          render partial: "subscriptions/results_frame"
        else
          render :index
        end
      end
    end
  end

  def calendar
    @month = parse_calendar_month(params[:month])
    @subscriptions = Current.family.recurring_transactions
                          .active_subscriptions
                          .includes(:merchant, :category, :subscription_service, :default_account)
                          .with_attached_logo

    @calendar_data = build_calendar_data(@subscriptions, @month)
    @monthly_total = calculate_monthly_total(@subscriptions)

    # Week stats for quick stats bar
    @today_subscriptions = @calendar_data[Date.current] || []
    @this_week_data = (Date.current.beginning_of_week..Date.current.end_of_week)
                        .flat_map { |d| @calendar_data[d] || [] }
    @this_week_total = @this_week_data.sum(Money.new(0, Current.family.currency)) do |s|
      subscription_amount_in_family_currency(s.amount_money.abs)
    end

    @feed_url = subscriptions_feed_url(token: Current.family.subscriptions_feed_token) if Current.family.subscriptions_feed_enabled?
    @breadcrumbs = [ [ t(".home"), root_path ], [ t("subscriptions.index.title"), subscriptions_path ], [ t(".title"), nil ] ]
  end

  # The subscriptions iCal feed (decision 41): off by default. Reset gives a
  # new link and the old one stops working; disable removes the link.
  def enable_feed
    Current.family.enable_subscriptions_feed!
    redirect_to calendar_subscriptions_path(anchor: "subscriptions-feed"), notice: t(".success")
  end

  def reset_feed
    Current.family.reset_subscriptions_feed!
    redirect_to calendar_subscriptions_path(anchor: "subscriptions-feed"), notice: t(".success")
  end

  def disable_feed
    Current.family.disable_subscriptions_feed!
    redirect_to calendar_subscriptions_path(anchor: "subscriptions-feed"), notice: t(".success")
  end

  def new
    @subscription = Current.family.recurring_transactions.new(
      subscription_state: "subscription",
      billing_cycle: "monthly",
      status: "active",
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: Date.current,
      amount: 0,
      currency: Current.family.currency
    )
    @subscription_services = SubscriptionService.alphabetically
    @accounts = Current.family.accounts.visible.alphabetically
    @exchange_rates = load_exchange_rates_for_form
    @breadcrumbs = [ [ t(".home"), root_path ], [ t("subscriptions.index.title"), subscriptions_path ], [ t(".title"), nil ] ]
  end

  def create
    @subscription = Current.family.recurring_transactions.new(subscription_params)
    @subscription.subscription_state = "subscription"
    @subscription.last_occurrence_date ||= Date.current
    @subscription.next_expected_date = calculate_next_expected_date(@subscription)

    if @subscription.save
      @subscription.logo.attach(params[:recurring_transaction][:logo]) if params.dig(:recurring_transaction, :logo).present?

      redirect_to subscriptions_path, notice: t("subscriptions.created")
    else
      @subscription_services = SubscriptionService.alphabetically
      @accounts = Current.family.accounts.visible.alphabetically
      @exchange_rates = load_exchange_rates_for_form
      render :new, status: :unprocessable_entity
    end
  end

  def show
    redirect_to edit_subscription_path(@subscription)
  end

  def edit
    @subscription_services = SubscriptionService.alphabetically
    @accounts = Current.family.accounts.visible.alphabetically
    @exchange_rates = load_exchange_rates_for_form
    @breadcrumbs = [ [ t(".home"), root_path ], [ t("subscriptions.index.title"), subscriptions_path ], [ @subscription.display_name, nil ] ]
  end

  def update
    # Only recalculate next_expected_date if billing day changed AND user didn't explicitly set next_expected_date
    billing_day_changed = subscription_params[:expected_day_of_month].present? &&
                          subscription_params[:expected_day_of_month].to_i != @subscription.expected_day_of_month
    user_set_next_date = subscription_params[:next_expected_date].present?

    if @subscription.update(subscription_params)
      if billing_day_changed && !user_set_next_date
        @subscription.next_expected_date = calculate_next_expected_date(@subscription)
        @subscription.save!
      end
      @subscription.logo.attach(params[:recurring_transaction][:logo]) if params.dig(:recurring_transaction, :logo).present?
      redirect_to subscriptions_path, notice: t("subscriptions.updated")
    else
      @subscription_services = SubscriptionService.alphabetically
      @accounts = Current.family.accounts.visible.alphabetically
      @exchange_rates = load_exchange_rates_for_form
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @subscription.destroy!

    if @subscription.subscription?
      redirect_to subscriptions_path, notice: t("subscriptions.deleted")
    else
      redirect_to subscriptions_path(kind: OTHER_RECURRING_KIND), notice: t(".other_recurring_deleted")
    end
  end

  # Turns an Other recurring row into a subscription, then opens it so the
  # billing cycle and payment account can be checked.
  def make_subscription
    @subscription.make_subscription!
    redirect_to edit_subscription_path(@subscription), notice: t(".success")
  rescue AASM::InvalidTransition, ActiveRecord::RecordInvalid => e
    Rails.logger.warn("make_subscription failed for recurring transaction #{@subscription.id}: #{e.message}")
    redirect_to subscriptions_path(kind: OTHER_RECURRING_KIND), alert: t(".failed")
  end

  # The "Detect recurring patterns automatically" toggle on the Suggestions
  # page. Turning it on schedules a detection run.
  def update_detection_settings
    enabled = params.expect(:recurring_detection_enabled) == "1"
    Current.family.update!(recurring_transactions_disabled: !enabled)
    RecurringTransaction.identify_patterns_for(Current.family) if enabled

    redirect_to suggestions_subscriptions_path, notice: enabled ? t(".enabled") : t(".disabled")
  end

  def toggle_status
    if @subscription.active?
      @subscription.mark_inactive!
      @new_status = "inactive"
    else
      @subscription.mark_active!
      @new_status = "active"
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to subscriptions_path }
    end
  end

  def record_transaction
    if @subscription.default_account.blank?
      redirect_to edit_subscription_path(@subscription), alert: t(".no_account")
      return
    end

    unless @subscription.actionable?
      redirect_to subscriptions_path, alert: t(".not_due")
      return
    end

    entry = @subscription.generate_transaction!
    if entry
      redirect_to subscriptions_path, notice: t(".success")
    elsif missing_rate_for_default_account?(@subscription)
      redirect_to subscriptions_path, alert: t(".no_exchange_rate", from: @subscription.currency, to: @subscription.default_account.currency)
    else
      redirect_to subscriptions_path, alert: t(".already_exists")
    end
  end

  def skip_occurrence
    # Skip by advancing one period from the current expected date, without
    # creating a transaction. (Computing from last_occurrence_date could land
    # on the date it already has.)
    @subscription.update!(
      next_expected_date: @subscription.calculate_next_expected_date(@subscription.next_expected_date)
    )
    redirect_to subscriptions_path, notice: t(".success")
  end

  def suggestions
    @suggestions = Current.family.recurring_transactions
                         .suggested
                         .includes(:merchant, :subscription_service)
                         .order(created_at: :desc)

    @dismissed_suggestions = Current.family.recurring_transactions
                                   .dismissed
                                   .includes(:merchant, :subscription_service)
                                   .order(dismissed_at: :desc)

    @detection_enabled = !Current.family.recurring_transactions_disabled?
    @breadcrumbs = [ [ t(".home"), root_path ], [ t("subscriptions.index.title"), subscriptions_path ], [ t(".title"), nil ] ]
  end

  def detect
    new_count = SubscriptionSuggestionService.new(Current.family).detect
    dismissed_count = Current.family.recurring_transactions.dismissed.count

    if new_count > 0
      redirect_to suggestions_subscriptions_path, notice: t(".found", count: new_count)
    elsif dismissed_count > 0
      redirect_to suggestions_subscriptions_path, notice: t(".none_new_with_dismissed", count: dismissed_count)
    else
      redirect_to subscriptions_path, notice: t(".none_found")
    end
  end

  def approve_suggestion
    use_base_currency = params[:use_base_currency] == "1"
    @suggestion.approve_suggestion!(use_base_currency: use_base_currency)

    @remaining_count = Current.family.recurring_transactions.suggested.count

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to suggestions_subscriptions_path, notice: t(".success") }
    end
  end

  def dismiss_suggestion
    @suggestion.dismiss_suggestion!

    @remaining_count = Current.family.recurring_transactions.suggested.count
    @dismissed_count = Current.family.recurring_transactions.dismissed.count

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to suggestions_subscriptions_path, notice: t(".success") }
    end
  end

  def restore_suggestion
    @suggestion = @dismissed_suggestion
    @suggestion.restore_suggestion!

    @remaining_dismissed_count = Current.family.recurring_transactions.dismissed.count

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to suggestions_subscriptions_path, notice: t(".success") }
    end
  end

  def approve_all_suggestions
    Current.family.recurring_transactions.suggested.find_each(&:approve_suggestion!)

    redirect_to subscriptions_path, notice: t(".success")
  end

  def dismiss_all_suggestions
    Current.family.recurring_transactions.suggested.find_each(&:dismiss_suggestion!)
    redirect_to subscriptions_path, notice: t(".success")
  end

  helper_method :should_remove_from_view?

  private

    def should_remove_from_view?(subscription)
      status_filter = params[:status]
      return false if status_filter.blank? # "All" tab

      (status_filter == "active" && subscription.inactive?) ||
        (status_filter == "inactive" && subscription.active?)
    end

    # A ?month= that is not a date shows the current month instead of failing
    def parse_calendar_month(value)
      return Date.current.beginning_of_month if value.blank?

      Date.parse(value.to_s).beginning_of_month
    rescue Date::Error
      Date.current.beginning_of_month
    end

    def set_subscription
      @subscription = Current.family.recurring_transactions.subscriptions.find(params[:id])
    end

    # Pause, resume, delete and "Make subscription" also work on manual
    # recurring rows (the Other recurring tab).
    def set_recurring_row
      @subscription = Current.family.recurring_transactions.user_managed.find(params[:id])
    end

    def set_suggestion
      @suggestion = Current.family.recurring_transactions.suggested.find(params[:id])
    end

    def set_dismissed_suggestion
      @dismissed_suggestion = Current.family.recurring_transactions.dismissed.find(params[:id])
    end

    def subscription_params
      params.expect(recurring_transaction: [
        :name, :amount, :currency, :billing_cycle, :expected_day_of_month, :expected_month,
        :category_id, :merchant_id, :subscription_service_id, :notes, :custom_logo_url, :status,
        :default_account_id, :next_expected_date
      ])
    end

    def calculate_next_expected_date(subscription)
      today = Date.current
      expected_day = subscription.expected_day_of_month || today.day

      # For yearly subscriptions with expected_month, use specific month
      if subscription.billing_cycle_yearly? && subscription.expected_month.present?
        target_year = today.year
        expected_month = subscription.expected_month

        # Try this year first
        begin
          this_year_date = Date.new(target_year, expected_month, expected_day)
          return this_year_date if this_year_date >= today
        rescue ArgumentError
          # Day doesn't exist, use end of month
          end_of_month = Date.new(target_year, expected_month, 1).end_of_month
          return end_of_month if end_of_month >= today
        end

        # Use next year
        target_year += 1
        begin
          Date.new(target_year, expected_month, expected_day)
        rescue ArgumentError
          Date.new(target_year, expected_month, 1).end_of_month
        end
      else
        # Monthly subscriptions or yearly without expected_month
        # Try this month first
        begin
          this_month_date = Date.new(today.year, today.month, expected_day)
          return this_month_date if this_month_date >= today
        rescue ArgumentError
          # Day doesn't exist in this month, use end of month
          return today.end_of_month if today.end_of_month >= today
        end

        # Use next period based on billing cycle
        if subscription.billing_cycle_yearly?
          next_period = today.next_year
        else
          next_period = today.next_month
        end

        begin
          Date.new(next_period.year, next_period.month, expected_day)
        rescue ArgumentError
          next_period.end_of_month
        end
      end
    end

    # Totals are computed from the subscriptions already loaded for the page,
    # rather than querying the same rows again for each total.
    def calculate_monthly_total(subscriptions)
      family_currency = Current.family.currency
      subscriptions.select(&:active?).sum(Money.new(0, family_currency)) do |sub|
        amount = sub.billing_cycle_yearly? ? sub.amount_money / 12 : sub.amount_money
        subscription_amount_in_family_currency(amount)
      end
    end

    def calculate_yearly_total(subscriptions)
      family_currency = Current.family.currency
      subscriptions.select(&:active?).sum(Money.new(0, family_currency)) do |sub|
        amount = sub.billing_cycle_monthly? ? sub.amount_money * 12 : sub.amount_money
        subscription_amount_in_family_currency(amount)
      end
    end

    # A subscription in a currency with no rate at all is left out of a total (and logged),
    # never counted at 1
    def subscription_amount_in_family_currency(amount)
      family_currency = Current.family.currency
      ExchangeRate.convert_or_leave_out(amount, to: family_currency, source: "SubscriptionsController#totals", family: Current.family) ||
        Money.new(0, family_currency)
    end

    # generate_transaction! books nothing when the subscription's currency has no rate at all
    # into its account's currency
    def missing_rate_for_default_account?(subscription)
      ExchangeRate.currencies_without_rate([ subscription.currency ], to: subscription.default_account.currency).any?
    end

    # The latest usable rate on or before today for each currency (the nearest-rate rule),
    # not only rates stored for today, which are missing until the day's sync has run.
    # Keyed "FROM_to_TO" as subscription_form_controller.js looks them up; it asks
    # GET /exchange_rate for a pair that is not here.
    def load_exchange_rates_for_form
      family_currency = Current.family.currency

      ExchangeRate.where(to_currency: family_currency)
                  .where("exchange_rates.date <= ? AND exchange_rates.rate > 0", Date.current)
                  .select("DISTINCT ON (exchange_rates.from_currency) exchange_rates.from_currency, exchange_rates.rate")
                  .order(:from_currency, date: :desc)
                  .to_h { |rate| [ "#{rate.from_currency}_to_#{family_currency}", rate.rate.to_f ] }
    end

    def build_calendar_data(subscriptions, month)
      start_date = month.beginning_of_month
      end_date = month.end_of_month

      # Build a hash of day => subscriptions
      calendar = {}
      (start_date..end_date).each { |date| calendar[date] = [] }

      subscriptions.each do |sub|
        # For monthly subscriptions, show on expected day
        # For yearly subscriptions, show only in the month they bill
        if sub.billing_cycle_monthly?
          day = [ sub.expected_day_of_month, end_date.day ].min
          date = Date.new(month.year, month.month, day)
          calendar[date] << sub if calendar[date]
        elsif sub.billing_cycle_yearly?
          # Show yearly subscription if next_expected_date is in this month
          if sub.next_expected_date.month == month.month && sub.next_expected_date.year == month.year
            calendar[sub.next_expected_date] << sub if calendar[sub.next_expected_date]
          end
        end
      end

      calendar
    end
end
