# The owner of this installation lives in Kyiv. Rails 7.2 on the production image did not
# offer Kyiv in the time zone list (the image has no zone file under the old name
# Europe/Kiev), so the family was set to Helsinki, which keeps the same clock. Rails 8.1
# offers Kyiv, and this moves the family to it. Both zones have the same offset and the
# same daylight-saving dates, so no date or time shown in the app changes.
class MoveHelsinkiFamiliesToKyivTimeZone < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE families SET timezone = 'Europe/Kyiv' WHERE timezone = 'Europe/Helsinki'"
  end

  def down
    execute "UPDATE families SET timezone = 'Europe/Helsinki' WHERE timezone = 'Europe/Kyiv'"
  end
end
