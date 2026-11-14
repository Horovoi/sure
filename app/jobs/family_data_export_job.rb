class FamilyDataExportJob < ApplicationJob
  queue_as :default

  def perform(family_export)
    family_export.generate!
  rescue => e
    Rails.logger.error "Family export failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
