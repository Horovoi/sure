class Tag < ApplicationRecord
  include FamilyUniqueName

  belongs_to :family
  has_many :taggings, dependent: :destroy
  has_many :transactions, through: :taggings, source: :taggable, source_type: "Transaction"
  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"

  validates :name, presence: true, uniqueness: { scope: :family }
  validates :name, exclusion: { in: ->(_) { [ UNTAGGED_FILTER_VALUE ] } }
  # Checked only when the colour changes, so an old row with another colour can still be renamed
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_nil: true, if: :will_save_change_to_color?

  scope :alphabetically, -> { order(:name) }

  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  UNCATEGORIZED_COLOR = "#737373"

  UNTAGGED_NAME_KEY = "models.tag.untagged"

  # Stable, non-localized transactions filter value of the synthetic "Untagged" option.
  # A real tag cannot take this name, so it never collides with one.
  UNTAGGED_FILTER_VALUE = "__untagged__"

  class << self
    # The synthetic "Untagged" option of the tag filter (not saved)
    def untagged
      new(name: untagged_name, color: UNCATEGORIZED_COLOR)
    end

    def untagged_name
      I18n.t(UNTAGGED_NAME_KEY)
    end
  end

  # The value the tag filter (q[tags][]) takes: the name of a real tag, the sentinel for the
  # synthetic "Untagged"
  def filter_value
    persisted? ? name : UNTAGGED_FILTER_VALUE
  end

  def replace_and_destroy!(replacement)
    transaction do
      raise ActiveRecord::RecordInvalid, "Replacement tag cannot be the same as the tag being destroyed" if replacement == self

      if replacement
        taggings.update_all tag_id: replacement.id
      end

      destroy!
    end
  end
end
