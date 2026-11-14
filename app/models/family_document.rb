# A family file uploaded to the vector store for the assistant's file search.
# pending (row and local copy saved) → processing (uploading) → ready (in the vector store) | error.
# "ready" means the provider accepted the file into the store; the provider indexes it asynchronously.
class FamilyDocument < ApplicationRecord
  include AASM

  belongs_to :family

  has_one_attached :file, dependent: :purge_later

  SUPPORTED_EXTENSIONS = VectorStore::Base::SUPPORTED_EXTENSIONS
  STATUSES = %w[pending processing ready error].freeze

  # An upload that has not finished in this time is lost; the stale work reaper marks it as an error
  STALE_AFTER = 30.minutes

  validates :filename, presence: true
  validates :status, inclusion: { in: STATUSES }

  aasm column: :status, whiny_persistence: true do
    state :pending, initial: true
    state :processing
    state :ready
    state :error

    event :start_upload do
      transitions from: :pending, to: :processing
    end

    # mark_ready!(provider_file_id)
    event :mark_ready do
      transitions from: :processing, to: :ready, after: :assign_provider_file_id
    end

    # mark_error!(message) — also the terminal event for the stale work reaper
    event :mark_error do
      transitions from: %i[pending processing], to: :error, after: :record_error
    end
  end

  scope :stale, -> { where(status: %w[pending processing]).where(updated_at: ...STALE_AFTER.ago) }

  def supported_extension?
    ext = File.extname(filename).downcase
    SUPPORTED_EXTENSIONS.include?(ext)
  end

  private
    def assign_provider_file_id(provider_file_id = nil)
      self.provider_file_id = provider_file_id
    end

    def record_error(error_message = nil)
      self.metadata = (metadata || {}).merge("error" => error_message)
    end
end
