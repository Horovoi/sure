# A name that is unique per family, backed by a unique index on
# [family_id, name] (categories and tags). The uniqueness validation catches
# the usual duplicate; the index catches two creates that race past it.
module FamilyUniqueName
  extend ActiveSupport::Concern

  class_methods do
    # Call it on a family's relation, e.g. family.tags.find_or_create_by_name!("Trip").
    # The block sets the attributes of a new record only. When another request
    # creates the same name in between, the record it created comes back. The
    # create runs in a savepoint, so a caller's open transaction stays usable.
    # previously_new_record? on the result tells whether this call created it.
    def find_or_create_by_name!(name, &block)
      find_by(name: name) || transaction(requires_new: true) { create!(name: name, &block) }
    rescue ActiveRecord::RecordNotUnique
      find_by!(name: name)
    rescue ActiveRecord::RecordInvalid => e
      # The other create committed between the lookup and the uniqueness check
      raise unless e.record.errors.of_kind?(:name, :taken)

      find_by(name: name) || raise
    end
  end
end
