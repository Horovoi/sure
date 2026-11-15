class FamilyResetJob < ApplicationJob
  queue_as :low_priority

  def perform(family, load_sample_data_for_email: nil)
    # Create a safety export before destroying any data
    create_pre_reset_export(family)

    # Delete all family data except users. The family row lock makes a second
    # concurrent reset wait for this one instead of interleaving with it.
    ActiveRecord::Base.transaction do
      family.lock!

      # Rules and recurring transactions point at the categories, merchants
      # and accounts deleted below, so they go too
      family.rules.destroy_all
      family.recurring_transactions.destroy_all

      # Delete accounts and related data
      family.accounts.destroy_all
      family.categories.destroy_all
      family.tags.destroy_all
      family.merchants.destroy_all
      BankConnections::ITEM_ASSOCIATIONS.each do |association|
        family.public_send(association).destroy_all
      end
      family.imports.destroy_all
      family.budgets.destroy_all
    end

    if load_sample_data_for_email.present?
      Demo::Generator.new.generate_new_user_data_for!(family.reload, email: load_sample_data_for_email)
    else
      family.sync_later
    end
  end

  private

    def create_pre_reset_export(family)
      return if family.accounts.empty?

      export = family.family_exports.create!
      export.generate!(filename_prefix: "pre_reset_")
      Rails.logger.info "[FamilyResetJob] Pre-reset export created: #{export.id}"
    rescue => e
      # Don't re-raise — reset should still proceed
      Rails.logger.error "[FamilyResetJob] Pre-reset export failed: #{e.message}"
    end
end
