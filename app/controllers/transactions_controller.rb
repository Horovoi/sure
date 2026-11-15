class TransactionsController < ApplicationController
  include EntryableResource
  include CategoryRulePrompt

  USER_SETTABLE_KINDS = %w[standard one_time].freeze

  before_action :store_params!, only: :index
  # Before the form options: a duplicate's nature decides which categories the form lists
  before_action :prefill_params_from_duplicate!, only: :new
  before_action :set_new_transaction_form_options, only: %i[new create]
  before_action :set_entry_for_tags, only: :update_tags

  def new
    super
    apply_duplicate_attributes!
  end

  def index
    @q = search_params
    @search = Transaction::Search.new(Current.family, filters: @q)

    base_scope = @search.transactions_scope
                       .reverse_chronological
                       .includes({ entry: :account }, *Transaction::ROW_ASSOCIATIONS)

    @pagy, @transactions = pagy(base_scope, limit: safe_per_page)

    # Upcoming: the next month of rows the user manages (manual recurring rows and
    # confirmed subscriptions). Detected patterns and suggestions stay off the list.
    @projected_recurring = Current.family.recurring_transactions
                                  .active
                                  .user_managed
                                  .where("next_expected_date <= ? AND next_expected_date >= ?",
                                         1.month.from_now.to_date,
                                         Date.current)
                                  .includes(merchant: { logo_attachment: :blob })

    respond_to do |format|
      format.html do
        if turbo_frame_request?
          render partial: "transactions/results_frame"
        else
          @uncategorized_count = uncategorized_transactions_count
          render :index
        end
      end

      # Optimize reactive search: stream updates to both summary and results
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "transactions_summary",
            partial: "transactions/summary_frame",
            locals: { totals: @search.totals }
          ),
          turbo_stream.replace(
            "transactions_results",
            partial: "transactions/results_frame"
          )
        ]
      end
    end
  end

  def clear_filter
    updated_params = {
      "q" => search_params,
      "page" => params[:page],
      "per_page" => params[:per_page]
    }

    q_params = updated_params["q"] || {}

    param_key = params[:param_key]
    param_value = params[:param_value]

    if q_params[param_key].is_a?(Array)
      q_params[param_key].delete(param_value)
      q_params.delete(param_key) if q_params[param_key].empty?
    else
      q_params.delete(param_key)
    end

    updated_params["q"] = q_params.presence

    # Add flag to indicate filters were explicitly cleared
    updated_params["filter_cleared"] = "1" if updated_params["q"].blank?

    Current.session.update!(prev_transaction_page_params: updated_params)

    redirect_to transactions_path(updated_params)
  end

  def create
    account = Current.family.accounts.find(params.dig(:entry, :account_id))
    @entry = account.entries.new(entry_params)

    if @entry.save
      @entry.transaction.record_category_usage!
      @entry.sync_account_later
      @entry.lock_saved_attributes!
      @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?

      flash[:notice] = t(".success")

      respond_to do |format|
        format.html { redirect_back_or_to account_path(@entry.account) }
        format.turbo_stream { stream_redirect_back_or_to(account_path(@entry.account)) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @entry.update(entry_params)
      # Read before the writes below reset saved_changes
      sync_needed = @entry.saved_changes_affect_balances?
      recurring_changed = @entry.saved_changes_affect_recurring_patterns?
      transaction = @entry.transaction
      transaction.record_category_usage!

      if needs_rule_notification?(transaction)
        flash[:cta] = {
          type: "category_rule",
          category_id: transaction.category_id,
          category_name: transaction.category.name
        }
      end

      @entry.lock_saved_attributes!
      @entry.mark_user_modified!
      @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?

      # A name, notes, category, merchant or tag edit changes no balance. The sync
      # would also have run the recurring-pattern detection, so ask for it directly.
      if sync_needed
        @entry.sync_account_later
      elsif recurring_changed
        RecurringTransaction.identify_patterns_for(Current.family)
      end

      respond_to do |format|
        format.html { redirect_back_or_to account_path(@entry.account), notice: t(".success") }
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              dom_id(@entry, :header),
              partial: "transactions/header",
              locals: { entry: @entry }
            ),
            turbo_stream.replace(@entry),
            *flash_notification_stream_items
          ]
        end
      end
    else
      render :show, status: :unprocessable_entity
    end
  end

  # The tag pickers: the edit drawer's DS::TagSelect sends the whole set
  # (tag_ids, JSON), the list row's picker toggles one tag (toggle_tag_id,
  # turbo stream).
  def update_tags
    if params[:toggle_tag_id].present?
      @toggled_tag = Current.family.tags.find(params[:toggle_tag_id])
      @entry.transaction.toggle_tag!(@toggled_tag)
    else
      @entry.transaction.tag_ids = Current.family.tags.where(id: tag_ids_param).pluck(:id)
    end

    @entry.lock_saved_attributes!
    @entry.mark_user_modified!
    @entry.transaction.lock_attr!(:tag_ids)
    @entry.sync_account_later

    respond_to do |format|
      # JSON stays first so Accept: */* callers keep the JSON response.
      format.json { render json: { tag_ids: @entry.transaction.tag_ids } }
      # Without Turbo the row picker's button_to posts as plain HTML.
      format.html { redirect_back_or_to transaction_path(@entry) }
      format.turbo_stream do
        transaction = @entry.transaction
        streams = [
          turbo_stream.replace(
            dom_id(transaction, :tag_summary_desktop),
            partial: "tags/summary",
            locals: { transaction: transaction }
          )
        ]
        if @toggled_tag
          # autofocus hands keyboard focus back to the re-rendered option,
          # which Turbo focuses after the stream renders.
          streams << turbo_stream.replace(
            "#{dom_id(@entry, :tag_option)}_#{@toggled_tag.id}",
            partial: "tag/dropdowns/row",
            locals: { tag: @toggled_tag, entry: @entry, selected: transaction.tag_ids.include?(@toggled_tag.id), autofocus: true }
          )
        end
        render turbo_stream: streams
      end
    end
  end

  def merge_duplicate
    transaction = Current.family.transactions.includes(entry: :account).find(params[:id])

    if transaction.merge_with_duplicate!
      flash[:notice] = t("transactions.merge_duplicate.success")
    else
      flash[:alert] = t("transactions.merge_duplicate.failure")
    end

    redirect_to transactions_path
  rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordInvalid => e
    Rails.logger.error("Failed to merge duplicate transaction #{params[:id]}: #{e.message}")
    flash[:alert] = t("transactions.merge_duplicate.failure")
    redirect_to transactions_path
  end

  def dismiss_duplicate
    transaction = Current.family.transactions.includes(entry: :account).find(params[:id])

    if transaction.dismiss_duplicate_suggestion!
      flash[:notice] = t("transactions.dismiss_duplicate.success")
    else
      flash[:alert] = t("transactions.dismiss_duplicate.failure")
    end

    redirect_back_or_to transactions_path
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Failed to dismiss duplicate suggestion for transaction #{params[:id]}: #{e.message}")
    flash[:alert] = t("transactions.dismiss_duplicate.failure")
    redirect_back_or_to transactions_path
  end

  def convert_to_trade
    @transaction = Current.family.transactions.includes(entry: :account).find(params[:id])
    @entry = @transaction.entry

    unless @entry.account.investment?
      flash[:alert] = t("transactions.convert_to_trade.errors.not_investment_account")
      redirect_back_or_to transactions_path
      return
    end

    render :convert_to_trade
  end

  def create_trade_from_transaction
    @transaction = Current.family.transactions.includes(entry: :account).find(params[:id])
    @entry = @transaction.entry

    # Pre-transaction validations
    unless @entry.account.investment?
      flash[:alert] = t("transactions.convert_to_trade.errors.not_investment_account")
      redirect_back_or_to transactions_path
      return
    end

    if @entry.excluded?
      flash[:alert] = t("transactions.convert_to_trade.errors.already_converted")
      redirect_back_or_to transactions_path
      return
    end

    # Deleting a transfer leg would turn the other leg into ordinary income or spending
    if @transaction.transfer.present?
      flash[:alert] = t("transactions.convert_to_trade.errors.transfer_leg")
      redirect_back_or_to transactions_path
      return
    end

    # Resolve security before transaction
    security = resolve_security_for_conversion
    return if performed? # Early exit if redirect already happened

    # Validate and calculate qty/price before transaction
    qty, price = calculate_qty_and_price
    return if performed? # Early exit if redirect already happened

    activity_label = params[:investment_activity_label].presence
    # Infer sell from amount sign: negative amount = money coming in = sell
    is_sell = activity_label == "Sell" || (activity_label.blank? && @entry.amount < 0)

    ActiveRecord::Base.transaction do
      # For trades: positive qty = buy (money out), negative qty = sell (money in)
      signed_qty = is_sell ? -qty : qty
      trade_amount = qty * price
      # Sells bring money in (negative amount), Buys take money out (positive amount)
      signed_amount = is_sell ? -trade_amount : trade_amount

      # Default activity label if not provided
      activity_label ||= is_sell ? "Sell" : "Buy"

      # Create trade entry
      @entry.account.entries.create!(
        name: params[:trade_name] || Trade.build_name(is_sell ? "sell" : "buy", qty, security.ticker),
        date: @entry.date,
        amount: signed_amount,
        currency: @entry.currency,
        entryable: Trade.new(
          security: security,
          qty: signed_qty,
          price: price,
          currency: @entry.currency,
          investment_activity_label: activity_label
        )
      )

      # The trade replaces the transaction. Balances count every entry (excluded ones too), so
      # keeping the original would move the cash twice.
      @entry.destroy!
    end

    @entry.account.sync_later(window_start_date: @entry.date)

    flash[:notice] = t("transactions.convert_to_trade.success")
    redirect_to account_path(@entry.account), status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    flash[:alert] = t("transactions.convert_to_trade.errors.conversion_failed", error: e.message)
    redirect_back_or_to transactions_path, status: :see_other
  rescue StandardError => e
    flash[:alert] = t("transactions.convert_to_trade.errors.unexpected_error", error: e.message)
    redirect_back_or_to transactions_path, status: :see_other
  end

  # Both actions land on the row that already has this transaction's identity
  # (see RecurringTransaction.mark_from_transaction!), so they never add a
  # second row next to a detected pattern or a suggestion.
  def mark_as_recurring
    transaction = Current.family.transactions.includes(entry: :account).find(params[:id])
    result = RecurringTransaction.mark_from_transaction!(transaction, as: :manual)

    if result.unchanged?
      key = result.recurring_transaction.subscription? ? "already_subscription" : "already_recurring"
      flash[:alert] = t("transactions.mark_as_recurring.#{key}")
    else
      flash[:notice] = t("transactions.mark_as_recurring.#{result.outcome == :converted ? "converted" : "success"}")
    end
    redirect_back_or_to transactions_path
  rescue ActiveRecord::RecordNotUnique
    flash[:alert] = t("transactions.mark_as_recurring.duplicate")
    redirect_back_or_to transactions_path
  rescue ActiveRecord::RecordInvalid
    flash[:alert] = t("transactions.mark_as_recurring.creation_failed")
    redirect_back_or_to transactions_path
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    Rails.logger.error("mark_as_recurring failed for transaction #{params[:id]}: #{e.class}: #{e.message}")
    flash[:alert] = t("transactions.mark_as_recurring.unexpected_error")
    redirect_back_or_to transactions_path
  end

  def mark_as_subscription
    transaction = Current.family.transactions.includes(entry: :account).find(params[:id])
    result = RecurringTransaction.mark_from_transaction!(transaction, as: :subscription)

    if result.unchanged?
      flash[:alert] = t("transactions.mark_as_subscription.already_subscription")
      redirect_back_or_to transactions_path
    else
      flash[:notice] = t("transactions.mark_as_subscription.success")
      redirect_to edit_subscription_path(result.recurring_transaction)
    end
  rescue ActiveRecord::RecordNotUnique
    flash[:alert] = t("transactions.mark_as_subscription.duplicate")
    redirect_back_or_to transactions_path
  rescue ActiveRecord::RecordInvalid, AASM::InvalidTransition
    flash[:alert] = t("transactions.mark_as_subscription.creation_failed")
    redirect_back_or_to transactions_path
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    Rails.logger.error("mark_as_subscription failed for transaction #{params[:id]}: #{e.class}: #{e.message}")
    flash[:alert] = t("transactions.mark_as_subscription.unexpected_error")
    redirect_back_or_to transactions_path
  end

  # The new-transaction form's name autocomplete (hotwire_combobox async source):
  # past names of this family's transactions, each with its usual category of
  # the form's nature.
  def name_suggestions
    classification = params[:nature] == "inflow" ? "income" : "expense"
    @suggestions = Transaction::NameSuggestion.for(Current.family, params[:q], classification: classification)
  end

  def update_preferences
    Current.user.update_transactions_preferences(preferences_params)
    head :ok
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved
    head :unprocessable_entity
  end

  private
    # --- Categorize wizard (w2-rules): the count on the wizard's link in the page header ---
    def uncategorized_transactions_count
      Current.family.entries.uncategorized_transactions.count
    end
    # --- end categorize wizard ---

    def entry_params
      entry_params = params.expect(entry: [
        :name, :date, :amount, :currency, :excluded, :notes, :nature, :entryable_type,
        entryable_attributes: [ :id, :category_id, :merchant_id, :kind, :investment_activity_label, { tag_ids: [] } ]
      ])

      nature = entry_params.delete(:nature)

      # A blank amount or date would set the saved value to nil, and the page shown again
      # needs both. Dropping it keeps the saved value on update; on create the entry's
      # presence validation still shows the form again.
      entry_params.delete(:amount) if entry_params[:amount].blank?
      entry_params.delete(:date) if entry_params[:date].blank?

      # A user can only toggle "one-time". Transfer kinds are written by Transfer alone, so a
      # transfer leg keeps its kind.
      if entry_params[:entryable_attributes]&.key?(:kind)
        kind = entry_params[:entryable_attributes][:kind]
        transfer_leg = @entry&.transaction? && @entry.transaction.transfer.present?

        entry_params[:entryable_attributes].delete(:kind) if transfer_leg || !kind.in?(USER_SETTABLE_KINDS)
      end

      if nature.present? && entry_params[:amount].present?
        signed_amount = nature == "inflow" ? -entry_params[:amount].to_d : entry_params[:amount].to_d
        entry_params = entry_params.merge(amount: signed_amount)
      end

      entry_params
    end

    def search_params
      cleaned_params = params.fetch(:q, {})
              .permit(
                :start_date, :end_date, :search, :amount,
                :amount_operator, :active_accounts_only,
                accounts: [], account_ids: [],
                categories: [], merchants: [], types: [], tags: [], status: []
              )
              .to_h
              .compact_blank

      cleaned_params.delete(:amount_operator) unless cleaned_params[:amount].present?


      cleaned_params
    end

    def store_params!
      if should_restore_params?
        params_to_restore = {}

        params_to_restore[:q] = stored_params["q"].presence || {}
        params_to_restore[:page] = stored_params["page"].presence || 1
        params_to_restore[:per_page] = stored_params["per_page"].presence || 50

        redirect_to transactions_path(params_to_restore)
      else
        Current.session.update!(
          prev_transaction_page_params: {
            q: search_params,
            page: params[:page],
            per_page: params[:per_page]
          }
        )
      end
    end

    def should_restore_params?
      return false if params[:clear_filters].present? || params[:filter_cleared].present?

      request.query_parameters.blank? && (stored_params["q"].present? || stored_params["page"].present? || stored_params["per_page"].present?)
    end

    def stored_params
      Current.session.prev_transaction_page_params
    end

    # A plain hash: the user model merges nested hashes, and it only recognises real ones
    def preferences_params
      params.expect(preferences: [ collapsed_sections: {} ]).to_h
    end

    # The new-transaction form's pickers. The category list follows the form's
    # nature (an income transaction picks from income categories), and so do
    # the recent categories and the classification of a category created inline.
    def set_new_transaction_form_options
      nature = params[:nature].presence || params.dig(:entry, :nature)
      @category_classification = nature == "inflow" ? "income" : "expense"
      @categories = Current.family.categories.where(classification: @category_classification).alphabetically_by_hierarchy.to_a
      @recent_categories = Category.recently_used_for(family: Current.family, classification: @category_classification).to_a
      @merchants = Current.family.available_merchants.with_attached_logo.alphabetically.to_a
      @tags = Current.family.tags.alphabetically.to_a
    end

    # Duplicate (the selection bars' copy button, decision 45: duplicate-and-edit
    # instead of splits): the new form opens filled from one of the family's
    # transactions, dated today, for the user to change and save.
    def duplicate_source
      return @duplicate_source if defined?(@duplicate_source)

      @duplicate_source = if params[:duplicate_entry_id].present?
        Current.family.entries.transactions.includes(:entryable).find_by(id: params[:duplicate_entry_id])
      end
    end

    def prefill_params_from_duplicate!
      return unless duplicate_source

      params[:nature] ||= duplicate_source.amount.negative? ? "inflow" : "outflow"
      # The form's account list holds manual, active accounts only
      if params[:account_id].blank? && Current.family.accounts.manual.active.exists?(id: duplicate_source.account_id)
        params[:account_id] = duplicate_source.account_id
      end
    end

    def apply_duplicate_attributes!
      return unless duplicate_source

      source = duplicate_source.transaction
      @entry.assign_attributes(
        name: duplicate_source.name,
        amount: duplicate_source.amount.abs,
        currency: duplicate_source.currency,
        notes: duplicate_source.notes
      )
      # Only values the form's pickers offer: a category of the other classification is left out
      @entry.entryable.category_id = source.category_id if @categories.any? { |category| category.id == source.category_id }
      @entry.entryable.merchant_id = source.merchant_id if @merchants.any? { |merchant| merchant.id == source.merchant_id }
      @entry.entryable.tag_ids = source.tag_ids & @tags.map(&:id)
    end

    def set_entry_for_tags
      @entry = Current.family.entries.transactions.find(params[:id])
    end

    def tag_ids_param
      Array(params[:tag_ids]).reject(&:blank?)
    end

    # Helper methods for convert_to_trade

    def resolve_security_for_conversion
      user_country = Current.family.country

      if params[:security_id] == "__custom__"
        # User selected "Enter custom ticker" - check for combobox selection or manual entry
        if params[:ticker].present?
          # Combobox selection: format is "SYMBOL|EXCHANGE"
          ticker_symbol, exchange_operating_mic = params[:ticker].split("|")
          Security::Resolver.new(
            ticker_symbol.strip,
            exchange_operating_mic: exchange_operating_mic.presence || params[:exchange_operating_mic].presence,
            country_code: user_country
          ).resolve
        elsif params[:custom_ticker].present?
          # Manual entry from combobox's name_when_new or fallback text field
          Security::Resolver.new(
            params[:custom_ticker].strip,
            exchange_operating_mic: params[:exchange_operating_mic].presence,
            country_code: user_country
          ).resolve
        else
          flash[:alert] = t("transactions.convert_to_trade.errors.enter_ticker")
          redirect_back_or_to transactions_path
          return nil
        end
      elsif params[:security_id].present?
        found = Security.find_by(id: params[:security_id])
        unless found
          flash[:alert] = t("transactions.convert_to_trade.errors.security_not_found")
          redirect_back_or_to transactions_path
          return nil
        end
        found
      elsif params[:ticker].present?
        # Direct combobox (no existing holdings) - format is "SYMBOL|EXCHANGE"
        ticker_symbol, exchange_operating_mic = params[:ticker].split("|")
        Security::Resolver.new(
          ticker_symbol.strip,
          exchange_operating_mic: exchange_operating_mic.presence || params[:exchange_operating_mic].presence,
          country_code: user_country
        ).resolve
      elsif params[:custom_ticker].present?
        # Manual entry from combobox's name_when_new (no existing holdings path)
        Security::Resolver.new(
          params[:custom_ticker].strip,
          exchange_operating_mic: params[:exchange_operating_mic].presence,
          country_code: user_country
        ).resolve
      end.tap do |security|
        if security.nil? && !performed?
          flash[:alert] = t("transactions.convert_to_trade.errors.select_security")
          redirect_back_or_to transactions_path
        end
      end
    end

    def calculate_qty_and_price
      amount = @entry.amount.abs
      qty = params[:qty].present? ? params[:qty].to_d.abs : nil
      price = params[:price].present? ? params[:price].to_d : nil

      if qty.nil? && price.nil?
        flash[:alert] = t("transactions.convert_to_trade.errors.enter_qty_or_price")
        redirect_back_or_to transactions_path, status: :see_other
        return [ nil, nil ]
      elsif qty.nil? && price.present? && price > 0
        qty = (amount / price).round(6)
      elsif price.nil? && qty.present? && qty > 0
        price = (amount / qty).round(4)
      end

      if qty.nil? || qty <= 0 || price.nil? || price <= 0
        flash[:alert] = t("transactions.convert_to_trade.errors.invalid_qty_or_price")
        redirect_back_or_to transactions_path, status: :see_other
        return [ nil, nil ]
      end

      [ qty, price ]
    end
end
