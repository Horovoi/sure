module TransactionsHelper
  def transaction_search_filters
    [
      { key: "account_filter", label: t("transactions.search.filters.account"), icon: "layers" },
      { key: "date_filter", label: t("transactions.search.filters.date"), icon: "calendar" },
      { key: "type_filter", label: t("transactions.search.filters.type"), icon: "tag" },
      { key: "status_filter", label: t("transactions.search.filters.status"), icon: "clock" },
      { key: "amount_filter", label: t("transactions.search.filters.amount"), icon: "hash" },
      { key: "category_filter", label: t("transactions.search.filters.category"), icon: "shapes" },
      { key: "tag_filter", label: t("transactions.search.filters.tag"), icon: "tags" },
      { key: "merchant_filter", label: t("transactions.search.filters.merchant"), icon: "store" },
      { key: "attachment_filter", label: t("transactions.search.filters.attachment"), icon: "paperclip" }, # w3-toolstrx
      { key: "reconcile_status_filter", label: t("transactions.search.filters.reconcile_status"), icon: "circle-check" } # w3-toolstrx
    ]
  end

  def get_transaction_search_filter_partial_path(filter)
    "transactions/searches/filters/#{filter[:key]}"
  end

  def account_search_filters
    transaction_search_filters
      .reject { |f| f[:key] == "account_filter" }
      .map { |f| f[:key] == "type_filter" ? f.merge(key: "account_type_filter") : f }
  end

  # The account an account_ids filter chip names (the dashboard drill-down filters by id),
  # or the value itself when it is no account of the family. One query per request.
  def transaction_filter_account_name(account_id)
    @transaction_filter_account_names ||= Current.family.accounts.pluck(:id, :name).to_h
    @transaction_filter_account_names.fetch(account_id.to_s, account_id.to_s)
  end

  # ---- Reconciliation status (w3-toolstrx reconciliation-status) ----
  # How each Entry#reconciled_status looks, for the row icon, the drawer pill, the
  # filter chip and the bulk menu alike
  RECONCILE_STATUS_PRESENTATION = {
    "unreconciled" => { tone: :neutral, icon: "circle", text_class: "text-secondary" },
    "cleared" => { tone: :warning, icon: "circle-dot", text_class: "text-warning" },
    "reconciled" => { tone: :success, icon: "circle-check", text_class: "text-success" }
  }.freeze

  def reconcile_status_presentation(status)
    RECONCILE_STATUS_PRESENTATION.fetch(status.to_s, RECONCILE_STATUS_PRESENTATION["unreconciled"])
  end

  # Whether the entry takes the reconciliation mark (Entry#reconcilable?), with the
  # family's manual accounts read once per request rather than once per row
  def entry_reconcilable?(entry)
    return false unless entry.transaction? && Current.family
    # A part of a split is checked off through its parent, the statement's line
    return false if entry.split_child?

    @reconcilable_account_ids ||= Current.family.accounts.manual.pluck(:id).to_set
    @reconcilable_account_ids.include?(entry.account_id)
  end

  # ---- Transaction extra details helpers ----
  # Returns a structured hash describing extra details for a transaction.
  # Input can be a Transaction or an Entry (responds_to :transaction).
  # Structure:
  #   {
  #     kind: :raw,
  #     provider_extras: [ { key:, value:, title: } ],
  #     raw: String (pretty JSON or string)
  #   }
  def build_transaction_extra_details(obj)
    tx = obj.respond_to?(:transaction) ? obj.transaction : obj
    return nil unless tx.respond_to?(:extra) && tx.extra.present?

    extra = tx.extra

    pretty = begin
      JSON.pretty_generate(extra)
    rescue StandardError
      extra.to_s
    end

    {
      kind: :raw,
      provider_extras: [],
      raw: pretty
    }
  end

  # The Expense / Income / Transfer tabs of the new-transaction dialog, styled as
  # DS::Tabs: the active tab is raised, the others only tinted on hover
  def transaction_type_tab_classes(active)
    class_names(
      "focus-ring flex items-center justify-center gap-2 rounded-md px-2 py-1 text-sm font-medium motion-safe:transition-colors motion-safe:duration-200",
      active ? "tab-item-active text-primary shadow-sm" : "text-secondary hover:bg-surface-inset-hover hover:text-primary"
    )
  end
end
