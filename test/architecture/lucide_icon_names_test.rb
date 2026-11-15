# frozen_string_literal: true

require "test_helper"

# lucide-rails raises "Unknown icon" while a page renders when it does not
# know an icon name. This test reads every literal icon name in app/ and
# checks that lucide-rails (or app/assets/images, for custom icons) has it,
# so a typo or a name that a gem update removes fails here and not on a page.
class LucideIconNamesTest < ActiveSupport::TestCase
  ICON_NAME = /
    (?:
      \bicon\(\s* | \bicon\s+ | \bicon:\s* | \bicon_name:\s* |
      \blucide_icon:\s* | \blucide_icon\(\s* | \blucide_icon\s*=\s*
    )
    "([a-z0-9][a-z0-9-]*)"
  /x

  test "every literal icon name in app/ exists in lucide-rails or app/assets/images" do
    custom = Dir[Rails.root.join("app/assets/images/**/*.svg")].map { |file| File.basename(file, ".svg") }.to_set
    unknown = literal_icon_names.reject { |name, _| custom.include?(name) || lucide_icon?(name) }

    assert_empty unknown, <<~MESSAGE
      These icon names do not exist in lucide-rails #{Gem.loaded_specs["lucide-rails"].version}:
      #{unknown.map { |name, places| "  #{name} (#{places.first(3).join(", ")})" }.join("\n")}
    MESSAGE
  end

  test "the scan finds the icon names it is meant to check" do
    names = literal_icon_names.keys

    # One of each call form: icon(...), icon: ..., icon_name: ..., lucide_icon: ...
    %w[chart-bar list-filter shapes arrow-right-left].each do |name|
      assert_includes names, name
    end
  end

  private
    def literal_icon_names
      @literal_icon_names ||= begin
        found = Hash.new { |hash, key| hash[key] = [] }
        Dir[Rails.root.join("app/**/*.{rb,erb}")].each do |file|
          relative = Pathname.new(file).relative_path_from(Rails.root).to_s
          File.foreach(file).with_index(1) do |line, number|
            line.scan(ICON_NAME) { |(name)| found[name] << "#{relative}:#{number}" }
          end
        end
        found
      end
    end

    def lucide_icon?(name)
      LucideRails::IconProvider.icon(name)
      true
    rescue ArgumentError
      false
    end
end
