class Import::AccountMapping < Import::Mapping
  validates :mappable, presence: true, if: :requires_mapping?

  class << self
    def mappables_by_key(import)
      unique_values = import.rows.map(&:account).uniq
      # Never match a disabled account or one being deleted. A name that is a linked
      # account's still matches it (a manual account of that name first), so the import
      # is refused with Import.provider_linked_message instead of quietly creating a
      # second account of that name.
      accounts = import.family.accounts.visible.where(name: unique_values).to_a
                       .sort_by { |account| account.linked? ? 1 : 0 }
                       .group_by(&:name).transform_values(&:first)

      unique_values.index_with { |value| accounts[value] }
    end
  end

  # Manual accounts to pick from; a linked account only while it is this mapping's
  # match, so the select shows what the import is refused for
  def selectable_values
    family_accounts = import.family.accounts.visible_manual.alphabetically.map { |account| [ account.name, account.id ] }
    if mappable.is_a?(Account) && mappable.linked?
      family_accounts.unshift [ mappable.name, mappable.id ]
    end

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
