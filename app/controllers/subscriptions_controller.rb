class SubscriptionsController < ApplicationController
  before_action :set_subscription, only: %i[show edit update destroy toggle_status record_transaction skip_occurrence]
  before_action :set_suggestion, only: %i[approve_suggestion dismiss_suggestion]

  def index
    @subscriptions = Current.family.recurring_transactions
                          .subscriptions
                          .includes(:merchant, :category, subscription_service: { icon_attachment: :blob })
                          .order(status: :asc, next_expected_date: :asc, name: :asc)

    # Apply filters
    @subscriptions = @subscriptions.active if params[:status] == "active"
    @subscriptions = @subscriptions.inactive if params[:status] == "inactive"
    @subscriptions = @subscriptions.where(billing_cycle: params[:billing_cycle]) if params[:billing_cycle].present?

    if params[:search].present?
      search_term = "%#{params[:search].downcase}%"
      @subscriptions = @subscriptions.joins("LEFT JOIN merchants ON merchants.id = recurring_transactions.merchant_id")
                                     .where("LOWER(recurring_transactions.name) LIKE ? OR LOWER(merchants.name) LIKE ?",
                                            search_term, search_term)
    end

    # Counts for subheader (before any filtering for accurate totals)
    all_subscriptions = Current.family.recurring_transactions.subscriptions
    @active_count = all_subscriptions.active.count
    @inactive_count = all_subscriptions.inactive.count
    @suggestion_count = Current.family.recurring_transactions.suggested.count

    @monthly_total = calculate_monthly_total(@subscriptions)
    @yearly_total = calculate_yearly_total(@subscriptions)
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
    @month = params[:month].present? ? Date.parse(params[:month]) : Date.current.beginning_of_month
    @subscriptions = Current.family.recurring_transactions
                          .active_subscriptions
                          .includes(:merchant, :category, subscription_service: { icon_attachment: :blob })

    @calendar_data = build_calendar_data(@subscriptions, @month)
    @monthly_total = calculate_monthly_total(@subscriptions)

    # Week stats for quick stats bar
    @today_subscriptions = @calendar_data[Date.current] || []
    @this_week_data = (Date.current.beginning_of_week..Date.current.end_of_week)
                        .flat_map { |d| @calendar_data[d] || [] }
    @this_week_total = @this_week_data.sum(Money.new(0, Current.family.currency)) do |s|
      amount = s.amount_money.abs
      s.currency == Current.family.currency ? amount : amount.exchange_to(Current.family.currency, fallback_rate: 1)
    end

    @breadcrumbs = [ [ t(".home"), root_path ], [ t("subscriptions.index.title"), subscriptions_path ], [ t(".title"), nil ] ]
  end

  def new
    @subscription = Current.family.recurring_transactions.new(
      is_subscription: true,
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
    @subscription.is_subscription = true
    @subscription.last_occurrence_date ||= Date.current
    @subscription.next_expected_date = calculate_next_expected_date(@subscription)

    if @subscription.save
      @subscription.logo.attach(params[:recurring_transaction][:logo]) if params.dig(:recurring_transaction, :logo).present?

      # Queue icon caching if subscription service is set and icon not cached
      if @subscription.subscription_service.present? && !@subscription.subscription_service.icon.attached?
        CacheSubscriptionIconJob.perform_later(@subscription.subscription_service)
      end

      redirect_to subscriptions_path, notice: t(".created")
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
      redirect_to subscriptions_path, notice: t(".updated")
    else
      @subscription_services = SubscriptionService.alphabetically
      @accounts = Current.family.accounts.visible.alphabetically
      @exchange_rates = load_exchange_rates_for_form
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @subscription.destroy!
    redirect_to subscriptions_path, notice: t(".deleted")
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

    entry = @subscription.generate_transaction!
    if entry
      redirect_to subscriptions_path, notice: t(".success")
    else
      redirect_to subscriptions_path, alert: t(".already_exists")
    end
  end

  def skip_occurrence
    # Skip by advancing to next expected date without creating a transaction
    @subscription.update!(
      next_expected_date: @subscription.calculate_next_expected_date
    )
    redirect_to subscriptions_path, notice: t(".success")
  end

  def suggestions
    @suggestions = Current.family.recurring_transactions
                         .suggested
                         .includes(:merchant, subscription_service: { icon_attachment: :blob })
                         .order(created_at: :desc)
    @breadcrumbs = [ [ t(".home"), root_path ], [ t("subscriptions.index.title"), subscriptions_path ], [ t(".title"), nil ] ]
  end

  def detect
    count = SubscriptionSuggestionService.new(Current.family).detect
    if count > 0
      redirect_to suggestions_subscriptions_path, notice: t(".found", count: count)
    else
      redirect_to subscriptions_path, notice: t(".none_found")
    end
  end

  def approve_suggestion
    service = @suggestion.subscription_service
    use_base_currency = params[:use_base_currency] == "1"
    @suggestion.approve_suggestion!(use_base_currency: use_base_currency)

    # Queue icon caching if subscription service is set and icon not cached
    if service.present? && !service.icon.attached?
      CacheSubscriptionIconJob.perform_later(service)
    end

    @remaining_count = Current.family.recurring_transactions.suggested.count

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to suggestions_subscriptions_path, notice: t(".success") }
    end
  end

  def dismiss_suggestion
    @suggestion.dismiss_suggestion!

    @remaining_count = Current.family.recurring_transactions.suggested.count

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to suggestions_subscriptions_path, notice: t(".success") }
    end
  end

  def approve_all_suggestions
    suggestions = Current.family.recurring_transactions.suggested.includes(:subscription_service)

    suggestions.find_each do |suggestion|
      service = suggestion.subscription_service
      suggestion.approve_suggestion!

      if service.present? && !service.icon.attached?
        CacheSubscriptionIconJob.perform_later(service)
      end
    end

    redirect_to subscriptions_path, notice: t(".success")
  end

  def dismiss_all_suggestions
    Current.family.recurring_transactions.suggested.find_each(&:dismiss_suggestion!)
    redirect_to subscriptions_path, notice: t(".success")
  end

  def fetch_exchange_rate
    from_currency = params[:from]&.upcase
    to_currency = Current.family.currency

    return render json: { error: "missing_currency" }, status: :bad_request unless from_currency
    return render json: { rate: 1 } if from_currency == to_currency

    rate = ExchangeRate.find_or_fetch_rate(from: from_currency, to: to_currency, date: Date.current, cache: true)

    if rate
      render json: { from: from_currency, to: to_currency, rate: rate.rate.to_f }
    else
      render json: { error: "rate_unavailable" }, status: :not_found
    end
  end

  helper_method :should_remove_from_view?

  private

    def should_remove_from_view?(subscription)
      status_filter = params[:status]
      return false if status_filter.blank? # "All" tab

      (status_filter == "active" && subscription.inactive?) ||
        (status_filter == "inactive" && subscription.active?)
    end

    def set_subscription
      @subscription = Current.family.recurring_transactions.subscriptions.find(params[:id])
    end

    def set_suggestion
      @suggestion = Current.family.recurring_transactions.suggested.find(params[:id])
    end

    def subscription_params
      params.require(:recurring_transaction).permit(
        :name, :amount, :currency, :billing_cycle, :expected_day_of_month, :expected_month,
        :category_id, :merchant_id, :subscription_service_id, :notes, :custom_logo_url, :status,
        :default_account_id, :next_expected_date
      )
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

    def calculate_monthly_total(subscriptions)
      family_currency = Current.family.currency
      subscriptions.active.sum(Money.new(0, family_currency)) do |sub|
        amount = sub.billing_cycle_yearly? ? sub.amount_money / 12 : sub.amount_money
        sub.currency == family_currency ? amount : amount.exchange_to(family_currency, fallback_rate: 1)
      end
    end

    def calculate_yearly_total(subscriptions)
      family_currency = Current.family.currency
      subscriptions.active.sum(Money.new(0, family_currency)) do |sub|
        amount = sub.billing_cycle_monthly? ? sub.amount_money * 12 : sub.amount_money
        sub.currency == family_currency ? amount : amount.exchange_to(family_currency, fallback_rate: 1)
      end
    end

    def load_exchange_rates_for_form
      ExchangeRate.where(to_currency: Current.family.currency, date: Date.current)
                  .pluck(:from_currency, :rate)
                  .to_h
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
