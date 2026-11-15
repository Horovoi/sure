# Rails 8.1.4 knows these two zones by their current names. The preferences form offers the
# name Rails knows, so a family stored under the old name would no longer match an option.
# (An earlier migration made the same change, but Rails 7.2 kept writing the old names.)
class RenameKyivAndYangonTimeZones < ActiveRecord::Migration[8.1]
  RENAMED = {
    "Europe/Kiev" => "Europe/Kyiv",
    "Asia/Rangoon" => "Asia/Yangon"
  }.freeze

  def up
    RENAMED.each do |old_name, new_name|
      execute "UPDATE families SET timezone = #{connection.quote(new_name)} WHERE timezone = #{connection.quote(old_name)}"
    end
  end

  # The old names still resolve to the same zones, so there is nothing to put back
  def down
  end
end
