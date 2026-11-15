# A family's choice of category for one Mcc::Taxonomy group. No row means automatic
# (Mcc::DefaultMapping picks a category by name). A row with disabled = true means
# "don't categorise"; a row with a category means that category. When the category
# is deleted the foreign key nullifies category_id and the group is automatic again.
#
# Family has no association for this model (bank-independent, added without touching
# Family): read it with MccCategoryMapping.where(family:).
class MccCategoryMapping < ApplicationRecord
  AUTOMATIC = "".freeze
  NONE = "none".freeze

  belongs_to :family
  belongs_to :category, optional: true

  validates :group_key, presence: true, uniqueness: { scope: :family_id }
  validates :group_key, inclusion: { in: ->(_) { Mcc::Taxonomy.mappable_keys } }
  validate :category_belongs_to_family

  class << self
    # Applies the settings form: { "groceries" => "", "taxi" => "none", "rent" => "<category id>" }.
    # "" removes the row (automatic), "none" stores disabled, a category id stores that
    # category. Unknown group keys and ids of other families' categories are ignored, and
    # groups missing from choices keep their row. Returns the number of groups changed.
    def apply!(family:, choices:)
      choices = choices.to_h.transform_keys(&:to_s).slice(*Mcc::Taxonomy.mappable_keys)
      category_ids = family.categories.where(id: choices.values.grep(uuid_format)).pluck(:id).to_set
      existing = where(family: family).index_by(&:group_key)

      changed = 0
      transaction do
        choices.each do |group_key, value|
          value = value.to_s.strip
          mapping = existing[group_key]

          if value == AUTOMATIC
            next unless mapping

            mapping.destroy!
          elsif value == NONE
            next if mapping&.disabled? && mapping.category_id.nil?

            mapping ||= new(family: family, group_key: group_key)
            mapping.update!(disabled: true, category_id: nil)
          elsif category_ids.include?(value)
            next if mapping && !mapping.disabled? && mapping.category_id == value

            mapping ||= new(family: family, group_key: group_key)
            mapping.update!(disabled: false, category_id: value)
          else
            next
          end

          changed += 1
        end
      end

      changed
    end

    private
      def uuid_format
        /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
      end
  end

  def group
    Mcc::Taxonomy.find(group_key)
  end

  # The value the settings select shows for this row: "none" or the category id.
  # A row whose category was deleted reads as automatic.
  def choice
    return NONE if disabled?

    category_id.presence || AUTOMATIC
  end

  private
    def category_belongs_to_family
      return if category.nil? || category.family_id == family_id

      errors.add(:category, :invalid)
    end
end
