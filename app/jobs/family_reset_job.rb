class FamilyResetJob < ApplicationJob
  queue_as :low_priority

  def perform(family, load_sample_data_for_email: nil)
    # Create a safety export before destroying any data
    create_pre_reset_export(family)

    # Delete all family data except users
    ActiveRecord::Base.transaction do
      # Delete accounts and related data
      family.accounts.destroy_all
      family.categories.destroy_all
      family.tags.destroy_all
      family.merchants.destroy_all
      family.plaid_items.destroy_all
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

      export = family.family_exports.create!(status: :processing)
      zip_data = Family::DataExporter.new(family).generate_export
      export.export_file.attach(
        io: zip_data,
        filename: "pre_reset_#{export.filename}",
        content_type: "application/zip"
      )
      export.update!(status: :completed)
      Rails.logger.info "[FamilyResetJob] Pre-reset export created: #{export.id}"
    rescue => e
      Rails.logger.error "[FamilyResetJob] Pre-reset export failed: #{e.message}"
      # Don't re-raise — reset should still proceed
    end
end
