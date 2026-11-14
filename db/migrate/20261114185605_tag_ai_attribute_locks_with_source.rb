# Attribute locks now record who set them ({ "source" => "ai" | "user", "locked_at" => ... }).
# Legacy locks are a bare timestamp and are read as user locks. This one-time
# fix re-tags the legacy locks that AI set: the transaction still holds the
# exact value an "ai" data enrichment wrote for that attribute.
# Idempotent: only bare (string) lock values are touched. The app reads both
# formats, so the previous app version keeps working.
class TagAiAttributeLocksWithSource < ActiveRecord::Migration[7.2]
  def up
    %w[category_id merchant_id].each do |attr|
      execute <<~SQL
        UPDATE transactions t
        SET locked_attributes = jsonb_set(
          t.locked_attributes,
          ARRAY['#{attr}'],
          jsonb_build_object('source', 'ai', 'locked_at', t.locked_attributes -> '#{attr}')
        )
        WHERE jsonb_typeof(t.locked_attributes -> '#{attr}') = 'string'
          AND t.#{attr} IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM data_enrichments de
            WHERE de.enrichable_type = 'Transaction'
              AND de.enrichable_id = t.id
              AND de.attribute_name = '#{attr}'
              AND de.source = 'ai'
              AND de.value = to_jsonb(t.#{attr}::text)
          )
      SQL
    end
  end

  def down
    # Lock values in the new format are still valid for older code (any
    # present value counts as a lock), so there is nothing to undo.
  end
end
