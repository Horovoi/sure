require "test_helper"
require "i18n/tasks"

# We're currently skipping some i18n tests to speed up development.  Eventually, we'll make a dedicated
# project for getting i18n working.  More details on that here:
# https://github.com/maybe-finance/maybe/issues/1225
class I18nTest < ActiveSupport::TestCase
  PLURAL_KEYS = %w[zero one two few many other].freeze

  def setup
    @i18n = I18n::Tasks::BaseTask.new
  end

  def test_no_missing_keys
    skip "Skipping missing keys test"
    missing_keys = @i18n.missing_keys(locales: [ :en ])
    assert_empty missing_keys,
                 "Missing #{missing_keys.leaves.count} i18n keys, run `i18n-tasks missing' to show them"
  end

  def test_no_unused_keys
    skip "Skipping unused keys test"
    unused_keys = @i18n.unused_keys(locales: [ :en ])
    assert_empty unused_keys,
                 "#{unused_keys.leaves.count} unused i18n keys, run `i18n-tasks unused' to show them"
  end

  def test_files_are_normalized
    skip "Skipping file normalization test"
    non_normalized = @i18n.non_normalized_paths(locales: [ :en ])
    error_message = "The following files need to be normalized:\n" \
                    "#{non_normalized.map { |path| "  #{path}" }.join("\n")}\n" \
                    "Please run `i18n-tasks normalize' to fix"
    assert_empty non_normalized, error_message
  end

  def test_no_inconsistent_interpolations
    skip "Skipping inconsistent interpolations test"
    inconsistent_interpolations = @i18n.inconsistent_interpolations(locales: [ :en ])
    error_message = "#{inconsistent_interpolations.leaves.count} i18n keys have inconsistent interpolations.\n" \
                    "Please run `i18n-tasks check-consistent-interpolations' to show them"
    assert_empty inconsistent_interpolations, error_message
  end
  # YAML lets the last of two equal keys win without a warning, so a duplicated
  # key hides the earlier definition (nl once had a flat transactions.merge_duplicate
  # string next to the success/failure mapping the controller reads). Walk the
  # raw YAML tree so a duplicate cannot come back.
  def test_no_duplicate_keys_within_locale_files
    offenses = locale_files.flat_map do |file|
      Psych.parse_stream(File.read(file), filename: file).children.flat_map do |document|
        duplicate_key_offenses(document.root, [], file)
      end
    end

    assert_empty offenses,
                 "Duplicate keys found in locale files (the last occurrence silently wins):\n" \
                 "#{offenses.map { |offense| "  #{offense}" }.join("\n")}"
  end

  # A placeholder the English string lacks is never passed by the caller, so I18n
  # raises MissingInterpolationArgument and the page breaks in that locale only.
  # Plural forms always get %{count}, and Rails passes every error message the
  # same set of values, so those two are allowed to differ.
  def test_no_locale_uses_placeholders_english_lacks
    leaves = locale_leaves
    english = leaves.fetch("en")

    offenses = leaves.except("en").flat_map do |locale, strings|
      strings.filter_map do |key, (value, file)|
        next if key.start_with?("errors.") || key.include?(".errors.")
        next unless english.key?(key)

        extra = placeholders(value) - placeholders(english[key].first)
        extra -= [ "count" ] if PLURAL_KEYS.include?(key.split(".").last)
        "#{file}: #{locale}.#{key} uses %{#{extra.join("}, %{")}}" if extra.any?
      end
    end

    assert_empty offenses, "Placeholders that English does not have:\n#{offenses.map { |offense| "  #{offense}" }.join("\n")}"
  end

  private
    def locale_files
      Dir[File.expand_path("../config/locales/**/*.yml", __dir__)].sort
    end

    # { "nl" => { "transactions.merge_duplicate.success" => [ "...", "config/locales/..." ] } }
    def locale_leaves
      locale_files.each_with_object(Hash.new { |hash, locale| hash[locale] = {} }) do |file, leaves|
        relative = Pathname.new(file).relative_path_from(Rails.root).to_s

        (YAML.load_file(file, aliases: true) || {}).each do |locale, tree|
          flatten_strings(tree).each { |key, value| leaves[locale.to_s][key] = [ value, relative ] } if tree.is_a?(Hash)
        end
      end
    end

    def flatten_strings(tree, prefix = nil)
      tree.each_with_object({}) do |(key, value), strings|
        path = [ prefix, key ].compact.join(".")

        case value
        when Hash then strings.merge!(flatten_strings(value, path))
        when String then strings[path] = value
        end
      end
    end

    def placeholders(string)
      string.scan(/%\{(\w+)\}/).flatten.uniq
    end

    def duplicate_key_offenses(node, path, file)
      case node
      when Psych::Nodes::Mapping
        first_lines = {}

        node.children.each_slice(2).flat_map do |key_node, value_node|
          next duplicate_key_offenses(value_node, path, file) unless key_node.is_a?(Psych::Nodes::Scalar)

          key_path = path + [ key_node.value ]
          offenses = []

          if (first_line = first_lines[key_node.value])
            offenses << "#{file}:#{key_node.start_line + 1} duplicate key `#{key_path.join(".")}` (first defined on line #{first_line})"
          else
            first_lines[key_node.value] = key_node.start_line + 1
          end

          offenses + duplicate_key_offenses(value_node, key_path, file)
        end
      when Psych::Nodes::Sequence
        node.children.flat_map { |child| duplicate_key_offenses(child, path, file) }
      else
        []
      end
    end
end
