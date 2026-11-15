require "test_helper"

class DS::ButtonTest < ViewComponent::TestCase
  # A <button> is a submit button by default, so a DS::Button inside a form used
  # to submit it, and took Enter-key submission from the form's own button.
  test "renders type=button by default" do
    render_inline(DS::Button.new(text: "Open"))

    assert_selector "button[type='button']", text: "Open"
  end

  test "renders type=submit when asked" do
    render_inline(DS::Button.new(text: "Save", type: :submit))

    assert_selector "button[type='submit']", text: "Save"
  end

  # With href the button sits in the form button_to builds, where submit is right.
  test "leaves the button_to submit alone when it has an href" do
    render_inline(DS::Button.new(text: "Delete", href: "/things/1", method: :delete))

    assert_selector "form[action='/things/1'] button[type='submit']", text: "Delete"
  end

  test "an icon-only button gets an aria-label from its icon" do
    render_inline(DS::Button.new(variant: "icon", icon: "more-horizontal"))

    assert_selector "button[aria-label='More horizontal']"
  end

  test "an icon with no text counts as icon-only in any variant" do
    render_inline(DS::Button.new(variant: "outline", icon: "plus"))

    assert_selector "button[aria-label='Plus']"
  end

  test "an explicit label wins over the icon fallback" do
    render_inline(DS::Button.new(variant: "icon", icon: "x", aria: { label: "Close" }))

    assert_selector "button[aria-label='Close']"
  end

  # Rails only dasherizes the nested aria hash, so a bare aria_label: used to
  # reach the page as a literal aria_label attribute.
  test "folds a bare aria_label option into aria-label" do
    render_inline(DS::Button.new(variant: "icon", icon: "x", aria_label: "Close"))

    assert_selector "button[aria-label='Close']"
    assert_no_selector "button[aria_label]"
  end

  test "a text button has no generated aria-label" do
    render_inline(DS::Button.new(text: "Save", icon: "check"))

    assert_no_selector "button[aria-label]"
  end

  test "carries the canonical focus ring" do
    render_inline(DS::Button.new(text: "Save"))

    assert_includes page.find("button")[:class].split, "focus-ring"
  end

  test "icon-only buttons keep 36px on a fine pointer and 44px on a coarse one" do
    render_inline(DS::Button.new(variant: "icon", icon: "x"))

    classes = page.find("button")[:class].split
    assert_includes classes, "w-9"
    assert_includes classes, "h-9"
    assert_includes classes, "pointer-coarse:w-11"
    assert_includes classes, "pointer-coarse:h-11"
  end

  test "a confirm turns into a Turbo confirm on the button" do
    render_inline(DS::Button.new(text: "Delete", type: :submit, confirm: "Sure?"))

    assert_selector "button[data-turbo-confirm='Sure?']"
  end
end
