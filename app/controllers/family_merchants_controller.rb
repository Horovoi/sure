class FamilyMerchantsController < ApplicationController
  before_action :set_merchant, only: %i[show clear_filter edit update destroy]

  def index
    @breadcrumbs = [ [ t(".breadcrumb_home"), root_path ], [ t(".title"), nil ] ]

    # Show all merchants for this family, searched and paged per section
    family_scope = Current.family.merchants.with_attached_logo.alphabetically
    @family_merchants_count = family_scope.count
    family_scope = name_search(family_scope, params[:family_search])
    @pagy_family_merchants, @family_merchants = pagy(family_scope, limit: safe_per_page(20), page_key: "family_page")

    provider_scope = Current.family.assigned_merchants.where(type: "ProviderMerchant").alphabetically
    @provider_merchants_count = provider_scope.count
    @pagy_provider_merchants, @provider_merchants = pagy(provider_scope, limit: safe_per_page(20), page_key: "provider_page")

    # Show recently unlinked ProviderMerchants (within last 30 days)
    # Exclude merchants that are already assigned to transactions (they appear in provider_merchants)
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: Current.family)
      .recently_unlinked
      .pluck(:merchant_id)
    assigned_ids = provider_scope.pluck(:id)
    @unlinked_merchants = ProviderMerchant.where(id: recently_unlinked_ids - assigned_ids).alphabetically

    render layout: "settings"
  end

  # The merchant's transactions across the family's accounts, with the transactions
  # page's search and filters. The totals are in the family currency, each amount at
  # the nearest stored rate (Transaction::Search#totals); an amount with no rate is
  # left out and the exchange rate notes say so.
  def show
    @q = merchant_search_params
    @breadcrumbs = [
      [ t(".breadcrumb_home"), root_path ],
      [ t("family_merchants.index.title"), family_merchants_path ],
      [ @merchant.name, nil ]
    ]

    @search = merchant_search
    # Spending is left out when the type filter hides expenses, so it never counts rows the list does not show
    if @q[:types].blank? || @q[:types].include?("expense")
      @expense_totals = merchant_search(types: [ "expense" ]).totals
      @average_expense_money = @expense_totals.expense_money / @expense_totals.count if @expense_totals.count.positive?
    end
    @first_date, @last_date = @search.transactions_scope.pick(Arel.sql("MIN(entries.date)"), Arel.sql("MAX(entries.date)"))

    @pagy, @transactions = pagy(
      @search.transactions_scope.reverse_chronological.includes({ entry: [ :account, { parent_entry: :child_entries } ] }, *Transaction::ROW_ASSOCIATIONS),
      limit: safe_per_page(50)
    )
  end

  # Removes one filter chip and keeps the others
  def clear_filter
    q = merchant_search_params
    param_key = params[:param_key].to_s

    # A blank value clears the whole key (the filters bar's collapsed badge)
    if q[param_key].is_a?(Array) && params[:param_value].present?
      q[param_key] = q[param_key] - [ params[:param_value].to_s ]
      q.delete(param_key) if q[param_key].empty?
    else
      q.delete(param_key)
    end
    q.delete("amount_operator") if param_key == "amount"

    redirect_to family_merchant_path(@merchant, { q: q.presence, per_page: params[:per_page].presence }.compact)
  end

  def new
    @family_merchant = FamilyMerchant.new(family: Current.family)
  end

  def create
    @family_merchant = FamilyMerchant.new(merchant_params.merge(family: Current.family))

    if @family_merchant.save
      respond_to do |format|
        format.html { redirect_to family_merchants_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
        # The merchant picker's inline create: the new option comes back to insert and select.
        format.json { render json: merchant_json(@family_merchant), status: :created }
      end
    else
      respond_to do |format|
        # No turbo_stream branch: forcing that format here would send the :new
        # HTML with a turbo-stream Content-Type, which Turbo ignores. Content
        # negotiation falls back to html, which renders :new as text/html.
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { errors: @family_merchant.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def edit
  end

  def update
    if @merchant.is_a?(ProviderMerchant)
      # Convert ProviderMerchant to FamilyMerchant for this family only
      @family_merchant = @merchant.convert_to_family_merchant_for(Current.family, merchant_params)
      # The page the user came from showed the provider merchant, which no longer
      # has this family's transactions; go to the new merchant's page instead
      return_path = return_path_for_update.start_with?(family_merchant_path(@merchant)) ? family_merchant_path(@family_merchant) : return_path_for_update
      respond_to do |format|
        format.html { redirect_to return_path, notice: t(".converted_success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, return_path) }
      end
    elsif @merchant.update(merchant_params)
      respond_to do |format|
        format.html { redirect_to return_path_for_update, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, return_path_for_update) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid => e
    @family_merchant = e.record
    render :edit, status: :unprocessable_entity
  end

  def destroy
    if @merchant.is_a?(ProviderMerchant)
      # Unlink from family's transactions only (don't delete the global merchant)
      @merchant.unlink_from_family(Current.family)
      redirect_to family_merchants_path, notice: t(".unlinked_success")
    else
      @merchant.destroy!
      redirect_to family_merchants_path, notice: t(".success")
    end
  end

  def merge
    @merchants = all_family_merchants.with_attached_logo
  end

  def perform_merge
    # Scope lookups to merchants valid for this family (FamilyMerchants + assigned ProviderMerchants)
    valid_merchants = all_family_merchants

    target = valid_merchants.find_by(id: params[:target_id])
    unless target
      return redirect_to merge_family_merchants_path, alert: t(".target_not_found")
    end

    sources = valid_merchants.where(id: params[:source_ids])
    unless sources.any?
      return redirect_to merge_family_merchants_path, alert: t(".invalid_merchants")
    end

    merger = Merchant::Merger.new(
      family: Current.family,
      target_merchant: target,
      source_merchants: sources
    )

    if merger.merge!
      redirect_to family_merchants_path, notice: t(".success", count: merger.merged_count)
    else
      redirect_to merge_family_merchants_path, alert: t(".no_merchants_selected")
    end
  rescue Merchant::Merger::UnauthorizedMerchantError => e
    redirect_to merge_family_merchants_path, alert: e.message
  end

  private
    def set_merchant
      # Find merchant that either belongs to family OR is assigned to family's transactions
      @merchant = Current.family.merchants.find_by(id: params[:id]) ||
                  Current.family.assigned_merchants.find(params[:id])
      @family_merchant = @merchant # For backwards compatibility with views
    end

    def merchant_params
      # Handle both family_merchant and provider_merchant param keys
      key = params.key?(:family_merchant) ? :family_merchant : :provider_merchant
      params.expect(key => [ :name, :color, :website_url, :logo, :remove_logo ])
    end

    # The merchant page's Edit link passes return_to (its full path, so a filtered or
    # paged page comes back the same); only a path on this site is followed.
    def return_path_for_update
      sanitize_return_to(params[:return_to]) || family_merchants_path
    end

    def merchant_search(**filters)
      Transaction::Search.new(Current.family, filters: { **@q.symbolize_keys, merchants: [ @merchant.name ], **filters })
    end

    # No merchants filter: the page fixes the merchant, so q[merchants] cannot switch it
    def merchant_search_params
      q = params.fetch(:q, {}).permit(
        :search, :start_date, :end_date, :amount, :amount_operator,
        accounts: [], categories: [], tags: [], types: [], status: []
      ).to_h.compact_blank
      q.delete("amount_operator") if q["amount"].blank?
      q
    end

    def name_search(scope, query)
      query = query.to_s.strip
      return scope if query.empty?

      scope.where("merchants.name ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(query)}%")
    end

    def merchant_json(merchant)
      merchant.as_json(only: %i[id name]).merge(
        html: render_to_string(
          partial: "DS/merchant_select/option",
          formats: [ :html ],
          locals: { merchant: merchant, selected: true, view_helpers: helpers }
        )
      )
    end

    def all_family_merchants
      family_merchant_ids = Current.family.merchants.pluck(:id)
      provider_merchant_ids = Current.family.assigned_merchants.where(type: "ProviderMerchant").pluck(:id)
      combined_ids = (family_merchant_ids + provider_merchant_ids).uniq

      Merchant.where(id: combined_ids)
              .order(Arel.sql("LOWER(COALESCE(name, ''))"))
    end
end
