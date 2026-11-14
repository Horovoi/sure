class FamilyExport < ApplicationRecord
  include AASM

  # How long an export may stay pending/processing before StaleWorkReaperJob fails it
  STALE_AFTER = 1.hour

  belongs_to :family

  has_one_attached :export_file, dependent: :purge_later

  aasm column: :status, requires_lock: true do
    state :pending, initial: true
    state :processing, :completed, :failed

    event :start do
      transitions from: :pending, to: :processing
    end

    event :complete do
      transitions from: :processing, to: :completed
    end

    event :fail do
      transitions from: %i[pending processing], to: :failed
    end
  end

  scope :ordered, -> { order(created_at: :desc) }
  scope :stale, -> { where(status: %w[pending processing]).where(updated_at: ...STALE_AFTER.ago) }

  # Builds the archive and attaches it. A redelivered job finds the export already processing
  # and carries on; one that already ended is left alone. A failure ends the export as failed
  # and is raised again for the caller to report.
  def generate!(filename_prefix: nil)
    return unless pending? || processing?

    start! if pending?
    export_file.attach(
      io: Family::DataExporter.new(family).generate_export,
      filename: "#{filename_prefix}#{filename}",
      content_type: "application/zip"
    )
    complete!
  rescue
    reload
    fail! if may_fail?
    raise
  end

  def filename
    "sure_export_#{created_at.strftime('%Y%m%d_%H%M%S')}.zip"
  end

  def downloadable?
    completed? && export_file.attached?
  end
end
