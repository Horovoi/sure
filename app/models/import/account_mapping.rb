class Import::AccountMapping < Import::Mapping
  validates :mappable, presence: true, if: :requires_mapping?

  class << self
    def mappables_by_key(import)
      unique_values = import.rows.map(&:account).uniq
      # Never match a disabled account, one being deleted, or one a bank connection
      # keeps (statement imports into it are refused)
      accounts = import.family.accounts.visible_manual.where(name: unique_values).index_by(&:name)

      unique_values.index_with { |value| accounts[value] }
    end
  end

  def selectable_values
    family_accounts = import.family.accounts.visible_manual.alphabetically.map { |account| [ account.name, account.id ] }

    unless key.blank?
      family_accounts.unshift [ "Add as new account", CREATE_NEW_KEY ]
    end

    family_accounts
  end

  def requires_selection?
    true
  end

  def values_count
    import.rows.where(account: key).count
  end

  def mappable_class
    Account
  end

  def create_mappable!
    return unless creatable?

    # Account names are not unique, so this always creates; existing accounts were
    # already matched by name in .mappables_by_key.
    account = import.family.accounts.create!(
      name: key,
      balance: 0,
      import: import,
      currency: import.family.currency,
      accountable: Depository.new
    )

    self.mappable = account
    save!
  end

  private
    def requires_mapping?
      (key.blank? || !create_when_empty) && import.account.nil?
    end
end
