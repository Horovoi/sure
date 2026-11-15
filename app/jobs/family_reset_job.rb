class FamilyResetJob < ApplicationJob
  queue_as :low_priority

  # Without a restorable copy nothing is deleted. The job is dropped rather than
  # retried, so Sidekiq never resets the family later, unseen; the user can start the
  # reset again.
  discard_on Backup::Bundle::Error do |job, error|
    Rails.logger.error("[FamilyResetJob] Pre-reset backup failed, nothing was deleted (family #{job.arguments.first&.id}): #{error.message}")
  end

  def perform(family, load_sample_data_for_email: nil)
    # A restorable copy of the whole database and the uploaded files comes first. It
    # raises Backup::Bundle::Error when it fails, which stops the reset here.
    create_pre_reset_bundle

    # Then the family's own export. It is a convenience, so a failure does not stop
    # the reset: the bundle above is the copy that can be restored.
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

    def create_pre_reset_bundle
      dir = Backup::Bundle.create!(kind: :pre_reset, parts: %i[db storage])
      Rails.logger.info "[FamilyResetJob] Pre-reset backup written: #{dir}"
    end

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
