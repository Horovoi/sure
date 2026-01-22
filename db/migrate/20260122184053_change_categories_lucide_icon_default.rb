class ChangeCategoriesLucideIconDefault < ActiveRecord::Migration[7.2]
  def up
    # Update existing categories with invalid icons to valid alternatives
    execute <<-SQL
      UPDATE categories
      SET lucide_icon = CASE lucide_icon
        WHEN 'shapes' THEN 'layers'
        WHEN 'circle-dollar-sign' THEN 'dollar-sign'
        WHEN 'store' THEN 'building'
        WHEN 'drama' THEN 'film'
        WHEN 'pill' THEN 'stethoscope'
        WHEN 'dumbbell' THEN 'target'
        WHEN 'hand-helping' THEN 'gift'
        WHEN 'receipt' THEN 'file-text'
        WHEN 'piggy-bank' THEN 'trending-up'
        WHEN 'cat' THEN 'layers'
        WHEN 'dog' THEN 'layers'
        WHEN 'paw-print' THEN 'layers'
        WHEN 'pen' THEN 'pencil'
        WHEN 'ribbon' THEN 'award'
        WHEN 'shopping-basket' THEN 'shopping-cart'
        WHEN 'sparkles' THEN 'star'
        WHEN 'unplug' THEN 'plug'
        WHEN 'handshake' THEN 'users'
        WHEN 'hotel' THEN 'building'
        WHEN 'house' THEN 'home'
        ELSE 'layers'
      END
      WHERE lucide_icon IN (
        'shapes', 'circle-dollar-sign', 'store', 'drama', 'pill', 'dumbbell',
        'hand-helping', 'receipt', 'piggy-bank', 'cat', 'dog', 'paw-print',
        'pen', 'ribbon', 'shopping-basket', 'sparkles', 'unplug', 'handshake',
        'hotel', 'house'
      )
    SQL

    # Change the default
    change_column_default :categories, :lucide_icon, 'layers'
  end

  def down
    change_column_default :categories, :lucide_icon, 'shapes'
  end
end
