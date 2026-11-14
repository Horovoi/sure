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
end
