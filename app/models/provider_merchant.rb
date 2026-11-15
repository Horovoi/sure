class ProviderMerchant < Merchant
  enum :source, { plaid: "plaid", lunchflow: "lunchflow", synth: "synth", ai: "ai", enable_banking: "enable_banking", coinstats: "coinstats", monobank: "monobank" }

  validates :name, uniqueness: { scope: [ :source ] }
  validates :source, presence: true

  # Convert this ProviderMerchant to a FamilyMerchant for a specific family.
  # Only affects transactions belonging to that family.
  # Returns the newly created FamilyMerchant.
  def convert_to_family_merchant_for(family, attributes = {})
    transaction do
      family_merchant = family.merchants.create!(
        name: attributes[:name].presence || name,
        color: attributes[:color].presence || FamilyMerchant::COLORS.sample,
        logo_url: logo_url,
        website_url: website_url
      )

      # Update only this family's transactions to point to new merchant
      family.transactions.where(merchant_id: id).update_all(merchant_id: family_merchant.id)

      # Recurring rows and subscriptions follow the transactions
      RecurringTransaction.reassign_merchant!(family.recurring_transactions.where(merchant_id: id), to_merchant: family_merchant)

      family_merchant
    end
  end

  # Unlink from family's transactions (set merchant_id to null).
  # Does NOT delete the ProviderMerchant since it may be used by other families.
  # Tracks the unlink in FamilyMerchantAssociation so it shows as "recently unlinked".
  def unlink_from_family(family)
    transaction do
      family.transactions.where(merchant_id: id).update_all(merchant_id: nil)

      # The family's recurring rows and subscriptions become name-based
      RecurringTransaction.reassign_merchant!(family.recurring_transactions.where(merchant_id: id), fallback_name: name)

      # Track that this merchant was unlinked from this family
      association = FamilyMerchantAssociation.find_or_initialize_by(family: family, merchant: self)
      association.update!(unlinked_at: Time.current)
    end
  end
end
