require "test_helper"

class DS::MenuTest < ViewComponent::TestCase
  test "is a strict action menu wired to its trigger" do
    render_inline(DS::Menu.new) do |menu|
      menu.with_item(variant: "link", text: "Edit", href: "/edit")
      menu.with_item(variant: "divider")
      menu.with_item(variant: "button", text: "Delete", href: "/delete", method: :delete)
    end

    content = page.find("[role='menu']", visible: :all)
    trigger = page.find("button[aria-haspopup='menu']")
    assert_equal content[:id], trigger[:"aria-controls"]
    assert_equal "false", trigger[:"aria-expanded"]
    assert_selector "[role='menu'] a[role='menuitem'][tabindex='-1']", text: "Edit", visible: :all
    assert_selector "[role='menu'] button[role='menuitem']", text: "Delete", visible: :all
    assert_selector "[role='menu'] [role='separator']", visible: :all
  end

  test "a button trigger gets the menu aria and type=button" do
    render_inline(DS::Menu.new(variant: "button")) do |menu|
      menu.with_button(text: "New", variant: "secondary", icon: "plus")
      menu.with_item(variant: "link", text: "Transaction", href: "/t")
    end

    assert_selector "button[type='button'][aria-haspopup='menu'][aria-expanded='false']", text: "New"
  end

  test "mixed content belongs in DS::Popover" do
    assert_raises(ArgumentError) { DS::Menu.new(variant: "avatar") }
    assert_not DS::Menu.method_defined?(:with_custom_content)
  end
end
