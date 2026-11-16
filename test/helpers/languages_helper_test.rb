require "test_helper"

class LanguagesHelperTest < ActionView::TestCase
  test "time zone options use the names Rails knows now" do
    identifiers = timezone_options.map(&:last)

    assert_includes identifiers, "Europe/Kyiv"
    assert_not_includes identifiers, "Europe/Kiev"
  end

  test "a stored zone that is no longer offered stays selectable" do
    assert_includes timezone_options("Europe/Kiev"), [ "Europe/Kiev", "Europe/Kiev" ]
    assert_equal timezone_options, timezone_options("Europe/Kyiv")
    assert_equal timezone_options, timezone_options(nil)
  end

  test "the scheduled jobs select sends Rails zone names under the same labels" do
    by_name = timezone_options(value: :name)

    assert_equal timezone_options.map(&:first), by_name.map(&:first)
    assert_includes by_name.map(&:last), "Kyiv"
  end
end
