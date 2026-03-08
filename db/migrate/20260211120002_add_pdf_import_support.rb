class AddPdfImportSupport < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :ai_summary, :text
    add_column :imports, :document_type, :string
    add_column :imports, :extracted_data, :jsonb, null: false, default: {}
  end
end
