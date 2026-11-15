# Categories and tags have a unique index on [family_id, name]. A save that
# races another request with the same name passes the uniqueness validation
# and then hits the index; report that as the same validation error.
module UniqueNameSaving
  extend ActiveSupport::Concern

  private
    def save_unique_name(record)
      record.save
    rescue ActiveRecord::RecordNotUnique
      record.errors.add(:name, :taken)
      false
    end
end
