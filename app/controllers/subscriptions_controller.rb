class SubscriptionsController < ApplicationController
  before_action :set_subscription, only: %i[show edit update destroy toggle_status]

  def index
    @subscriptions = Current.family.recurring_transactions
                          .subscriptions
                          .includes(:merchant, :category)
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
                          .includes(:merchant, :category)

    @calendar_data = build_calendar_data(@subscriptions, @month)
    @monthly_total = calculate_monthly_total(@subscriptions)
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
    @breadcrumbs = [ [ t(".home"), root_path ], [ t("subscriptions.index.title"), subscriptions_path ], [ t(".title"), nil ] ]
  end

  def create
    @subscription = Current.family.recurring_transactions.new(subscription_params)
    @subscription.is_subscription = true
    @subscription.last_occurrence_date ||= Date.current
    @subscription.next_expected_date = calculate_next_expected_date(@subscription)

    if @subscription.save
      @subscription.logo.attach(params[:recurring_transaction][:logo]) if params.dig(:recurring_transaction, :logo).present?
      redirect_to subscriptions_path, notice: t(".created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    redirect_to edit_subscription_path(@subscription)
  end

  def edit
    @breadcrumbs = [ [ t(".home"), root_path ], [ t("subscriptions.index.title"), subscriptions_path ], [ @subscription.display_name, nil ] ]
  end

  def update
    if @subscription.update(subscription_params)
      @subscription.next_expected_date = calculate_next_expected_date(@subscription)
      @subscription.save!
      @subscription.logo.attach(params[:recurring_transaction][:logo]) if params.dig(:recurring_transaction, :logo).present?
      redirect_to subscriptions_path, notice: t(".updated")
    else
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

    def subscription_params
      params.require(:recurring_transaction).permit(
        :name, :amount, :currency, :billing_cycle, :expected_day_of_month,
        :category_id, :merchant_id, :notes, :custom_logo_url, :status
      )
    end

    def calculate_next_expected_date(subscription)
      today = Date.current
      expected_day = subscription.expected_day_of_month || today.day

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

    def calculate_monthly_total(subscriptions)
      total = subscriptions.active.sum do |sub|
        sub.billing_cycle_yearly? ? (sub.amount / 12) : sub.amount
      end
      Money.new(total, Current.family.currency)
    end

    def calculate_yearly_total(subscriptions)
      total = subscriptions.active.sum do |sub|
        sub.billing_cycle_monthly? ? (sub.amount * 12) : sub.amount
      end
      Money.new(total, Current.family.currency)
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
