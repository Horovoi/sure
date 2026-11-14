# Import status is now an AASM state machine. This gives the column a default,
# forbids NULL, and maps PDF imports onto the new PDF processing states:
#   - pending/importing without an AI summary  -> processing (AI work never finished)
#   - failed before any rows could be reviewed -> processing_failed (retryable)
#   - complete with no rows                    -> indexed (stored in the vault, nothing published)
# The previous app version still reads these rows; it only shows an unknown state for the
# new PDF values. Idempotent: each statement only touches rows still in the old shape.
class NormalizeImportStatuses < ActiveRecord::Migration[7.2]
  def up
    execute "UPDATE imports SET status = 'pending' WHERE status IS NULL"

    execute <<~SQL
      UPDATE imports SET status = 'processing'
      WHERE type = 'PdfImport' AND status IN ('pending', 'importing') AND ai_summary IS NULL
    SQL

    execute <<~SQL
      UPDATE imports SET status = 'processing_failed'
      WHERE type = 'PdfImport' AND status = 'failed' AND rows_count = 0
    SQL

    execute <<~SQL
      UPDATE imports SET status = 'indexed'
      WHERE type = 'PdfImport' AND status = 'complete' AND rows_count = 0
    SQL

    change_column_default :imports, :status, from: nil, to: "pending"
    change_column_null :imports, :status, false
  end

  def down
    change_column_null :imports, :status, true
    change_column_default :imports, :status, from: "pending", to: nil

    execute "UPDATE imports SET status = 'pending' WHERE status IN ('processing', 'reverted')"
    execute "UPDATE imports SET status = 'failed' WHERE status = 'processing_failed'"
    execute "UPDATE imports SET status = 'complete' WHERE status = 'indexed'"
  end
end
