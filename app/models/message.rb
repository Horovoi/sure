class Message < ApplicationRecord
  belongs_to :chat
  has_many :tool_calls, dependent: :destroy

  validates :content, presence: true, unless: :blank_content_allowed?

  after_create_commit -> { broadcast_append_to chat, target: "messages" }, if: :broadcast?
  # Replace, not update: the re-rendered element (with its id and data attributes) takes the old one's place
  after_update_commit -> { broadcast_replace_to chat }, if: :broadcast?

  scope :ordered, -> { order(created_at: :asc) }

  private
    def broadcast?
      true
    end

    def blank_content_allowed?
      false
    end
end
