require "test_helper"

class DS::SearchInputTest < ViewComponent::TestCase
  test "standalone renders a bordered search field with the canonical focus ring" do
    render_inline(DS::SearchInput.new(name: "q", placeholder: "Search currencies", value: "UAH"))

    assert_selector "div.relative > input[type='search'][name='q'][value='UAH'][autocomplete='off'].focus-ring.border"
    # The placeholder doubles as the accessible name.
    assert_selector "input[aria-label='Search currencies'][placeholder='Search currencies']"
    assert_selector "div.pointer-events-none svg"
  end

  test "embedded drops its own border and focus ring for the parent panel's" do
    render_inline(DS::SearchInput.new(variant: :embedded, placeholder: "Search"))

    input = page.find("input[type='search']")
    refute_includes input[:class], "focus-ring"
    assert_includes input[:class], "border-none"
    assert_no_selector "div.pointer-events-none"
  end

  test "an explicit aria label wins and other options reach the input" do
    render_inline(DS::SearchInput.new(placeholder: "Search", aria_label: "Filter icons", class: "mb-2", data: { list_filter_target: "input" }))

    assert_selector "div.relative.mb-2 > input[aria-label='Filter icons'][data-list-filter-target='input']"
  end

  test "rejects an unknown variant" do
    assert_raises(ArgumentError) { DS::SearchInput.new(variant: :floating) }
  end
end
