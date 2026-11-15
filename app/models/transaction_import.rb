class TransactionImport < Import
  def import!
    transaction do
      mappings.each(&:create_mappable!)

      plan = duplicate_plan(strict: true)

      new_transactions = []
      updated_entries = []

      rows.ordered.each do |row|
        # Already recorded under another name or a date up to 3 days off: skipped,
        # and the entry is left as it is (decision 27)
        next if plan.skipped.key?(row.id)

        mapped_account = plan.accounts.fetch(row.id)
        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact
        effective_currency = row_currency(row, mapped_account)

        if (duplicate_entry = plan.claims[row.id])
          # Same date, amount and name: the import takes the entry over.
          # Remember what the entry looked like so revert can restore it.
          claim_entry!(duplicate_entry)

          # Update existing transaction instead of creating a new one
          duplicate_entry.transaction.category = category if category.present?
          duplicate_entry.transaction.tags = tags if tags.any?
          duplicate_entry.notes = row.notes if row.notes.present?
          duplicate_entry.import = self
          duplicate_entry.import_locked = true  # Protect from provider sync overwrites
          updated_entries << duplicate_entry
        else
          # Create new transaction (no duplicate found)
          # Mark as import_locked to protect from provider sync overwrites
          new_transactions << Transaction.new(
            category: category,
            tags: tags,
            entry: Entry.new(
              account: mapped_account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: effective_currency,
              notes: row.notes,
              import: self,
              import_locked: true
            )
          )
        end
      end

      # Save updated entries first
      updated_entries.each do |entry|
        entry.transaction.save!
        entry.save!
      end

      # Bulk import new transactions
      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  # Use the account's currency when no currency column was mapped, with the family
  # currency as fallback
  def row_currency(row, account)
    currency_col_label.present? ? row.currency : (account.currency.presence || family.currency)
  end

  # { row id => Entry } for rows an account already records under a different name
  # or a date up to 3 days off. Publishing skips them. Rows with the same date, amount
  # and name are not listed: publishing takes those entries over (and revert hands
  # them back).
  def already_recorded
    preview_plan.skipped
  end

  # { row id => Entry } for rows with the same date, amount and name as an existing
  # entry. Publishing takes those entries over instead of creating new ones.
  def already_claimed
    preview_plan.claims
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    base = %i[date amount name currency category tags notes]
    base.unshift(:account) if account.nil?
    base
  end

  def mapping_steps
    base = [ Import::CategoryMapping, Import::TagMapping ]
    base << Import::AccountMapping if account.nil?
    base
  end

  def selectable_amount_type_values
    return [] if entity_type_col_label.nil?

    csv_rows.map { |row| row[entity_type_col_label] }.uniq
  end

  def csv_template
    template = <<-CSV
      date*,amount*,name,currency,category,tags,account,notes
      05/15/2024,-45.99,Grocery Store,USD,Food,groceries|essentials,Checking Account,Monthly grocery run
      05/16/2024,1500.00,Salary,,Income,,Main Account,
      05/17/2024,-12.50,Coffee Shop,,,coffee,,
    CSV

    csv = CSV.parse(template, headers: true)
    csv.delete("account") if account.present?
    csv
  end

  private
    DuplicatePlan = Data.define(:accounts, :claims, :skipped)

    # The plan the confirm step shows, built once for both lists
    def preview_plan
      @preview_plan ||= duplicate_plan
    end

    # Decides, before anything is written, what happens to each row:
    # - accounts: row id => the account it goes into
    # - claims:   row id => an entry with the same date, amount and name (no external
    #             id), which the import takes over
    # - skipped:  row id => an entry the Import::DuplicateMatcher found (any name,
    #             up to 3 days off), which stays untouched
    # strict raises Import::MappingError for a row whose account is not mapped; the
    # preview leaves such rows out instead.
    def duplicate_plan(strict: false)
      accounts = {}
      claims = {}
      claimed_entry_ids = Set.new # identical rows within the file each get their own entry
      adapters = {}
      account_mappings = account ? {} : mappings.accounts.includes(:mappable).index_by(&:key)

      ordered_rows = rows.ordered.to_a

      ordered_rows.each_with_index do |row, index|
        mapped_account = account || account_mappings[row.account]&.mappable

        # Guard against nil account - this happens when an account name in CSV is not mapped
        if mapped_account.nil?
          next unless strict

          account_name = row.account.presence || "(blank)"
          error_message = "Row #{index + 1}: Account '#{account_name}' is not mapped to an existing account. " \
                          "Please map this account in the import configuration."
          errors.add(:base, error_message)
          raise Import::MappingError, error_message
        end

        accounts[row.id] = mapped_account
        next if mapped_account.new_record? || row.parsed_date.nil? || row.parsed_signed_amount.nil?

        adapter = adapters[mapped_account.id] ||= Account::ProviderImportAdapter.new(mapped_account)
        duplicate_entry = adapter.find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: row_currency(row, mapped_account),
          name: row.name,
          exclude_entry_ids: claimed_entry_ids
        )

        if duplicate_entry
          claims[row.id] = duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)
        end
      end

      skipped = {}
      unclaimed_rows = ordered_rows.select { |row| accounts.key?(row.id) && !claims.key?(row.id) }

      unclaimed_rows.group_by { |row| accounts[row.id] }.each do |mapped_account, account_rows|
        next if mapped_account.new_record?

        skipped.merge!(
          Import::DuplicateMatcher.new(
            import: self,
            account: mapped_account,
            rows: account_rows,
            exclude_entry_ids: claimed_entry_ids
          ).matches
        )
      end

      DuplicatePlan.new(accounts: accounts, claims: claims, skipped: skipped)
    end
end
