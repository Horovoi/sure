require "test_helper"

class DS::MenuItemTest < ViewComponent::TestCase
  test "selectable item reserves a fixed-width check gutter and shows the check when selected" do
    render_inline(DS::MenuItem.new(variant: :link, text: "30D", href: "/", selected: true))

    assert_selector "span.shrink-0.w-5", count: 1
    assert_selector "span.shrink-0.w-5 svg", count: 1
    # Selection is exposed to assistive tech, not only visually.
    assert_selector "a[role='menuitemradio'][aria-checked='true']"
    assert_text "30D"
  end

  test "selectable item keeps the reserved gutter (no glyph) when not selected" do
    render_inline(DS::MenuItem.new(variant: :link, text: "90D", href: "/", selected: false))

    # Gutter still present so text stays aligned with the selected row...
    assert_selector "span.shrink-0.w-5", count: 1
    # ...but no check glyph is drawn.
    assert_no_selector "span.shrink-0.w-5 svg"
    assert_selector "a[role='menuitemradio'][aria-checked='false']"
  end

  test "plain action item (selected: nil) renders no check gutter" do
    render_inline(DS::MenuItem.new(variant: :link, text: "Edit", href: "/", icon: "pencil-line"))

    assert_no_selector "span.shrink-0.w-5"
    assert_selector "a[role='menuitem']"
    assert_no_selector "[aria-checked]"
    assert_text "Edit"
  end

  test "a roving item shows keyboard focus as the hover fill, not a ring" do
    render_inline(DS::MenuItem.new(variant: :link, text: "Edit", href: "/"))

    classes = page.find("a[role='menuitem']")[:class].split
    assert_includes classes, "hover:bg-container-hover"
    assert_includes classes, "focus-visible:bg-container-hover"
    assert_includes classes, "outline-none"
    refute_includes classes, "focus-ring"
  end

  test "a destructive roving item takes the red tint on focus too" do
    render_inline(DS::MenuItem.new(variant: :button, text: "Delete", href: "/", method: :delete))

    classes = page.find("button[role='menuitem']")[:class].split
    assert_includes classes, "focus-visible:bg-red-tint-5"
  end

  test "an item in a popover (not roving) stays in the Tab order with the focus ring" do
    render_inline(DS::MenuItem.new(variant: :link, text: "Edit", href: "/", roving: false))

    classes = page.find("a")[:class].split
    assert_includes classes, "focus-ring"
    refute_includes classes, "outline-none"
  end
end
