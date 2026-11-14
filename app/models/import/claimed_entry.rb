# A pre-existing entry that an import matched as a duplicate and took over, with the
# values the import overwrote. Reverting or deleting the import restores them.
class Import::ClaimedEntry < ApplicationRecord
  self.table_name = "import_claimed_entries"

  belongs_to :import
  belongs_to :entry
end
