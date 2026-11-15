require "test_helper"

class DS::DialogTest < ViewComponent::TestCase
  # Turbo caches a page as it was left, and Back restores that copy. A drawer or
  # modal fetched into the page came back with it: stray and non-modal if it was
  # still open, opened again if it had been closed.
  test "a drawer fetched into its frame is left out of Turbo's page cache" do
    vc_test_request.headers["Turbo-Frame"] = "drawer"
    render_inline(DS::Dialog.new(frame: "drawer", responsive: true))

    assert_selector "turbo-frame#drawer > dialog[data-turbo-temporary]"
  end

  test "a drawer fetched into a frame of its own is left out of Turbo's page cache" do
    vc_test_request.headers["Turbo-Frame"] = "bulk_transaction_edit_drawer"
    render_inline(DS::Dialog.new(variant: "drawer", frame: "bulk_transaction_edit_drawer"))

    assert_selector "turbo-frame#bulk_transaction_edit_drawer > dialog[data-turbo-temporary]"
  end

  # Visited directly, the drawer is the page, and Back has to bring it back.
  test "a drawer rendered as the page stays in the cache" do
    render_inline(DS::Dialog.new(frame: "drawer", responsive: true))

    assert_selector "turbo-frame#drawer > dialog"
    assert_no_selector "dialog[data-turbo-temporary]"
  end

  # Transaction, trade and other detail drawers put this button in their
  # custom headers and have no other way out on a phone.
  test "a responsive dialog's close button shows at every width" do
    dialog = DS::Dialog.new(frame: "drawer", responsive: true)
    render_inline(dialog) do
      dialog.with_header(custom_header: true) { dialog.close_button }
    end

    close = page.find("button[data-action='DS--dialog#close']")
    refute_includes close[:class].split, "hidden"
  end

  test "a modal fetched into the modal frame is left out of Turbo's page cache" do
    vc_test_request.headers["Turbo-Frame"] = "modal"
    render_inline(DS::Dialog.new)

    assert_selector "turbo-frame#modal > dialog[data-turbo-temporary]"
  end

  test "the dialog is labelled by its title" do
    dialog = DS::Dialog.new
    render_inline(dialog) { dialog.with_header(title: "Edit account") }

    labelled_by = page.find("dialog")[:"aria-labelledby"]
    assert_selector "h2##{labelled_by}", text: "Edit account"
    assert_selector "dialog[role='dialog'][aria-modal='true']"
  end

  test "heading_level picks the title element" do
    dialog = DS::Dialog.new(heading_level: 3)
    render_inline(dialog) { dialog.with_header(title: "Nested") }

    assert_selector "h3", text: "Nested"
    assert_raises(ArgumentError) { DS::Dialog.new(heading_level: 7) }
  end

  test "the header shows a meta chip with its id" do
    dialog = DS::Dialog.new(width: "xl")
    render_inline(dialog) { dialog.with_header(title: "Net worth", meta: "Last 30 days", meta_id: "netWorthFullscreenPeriod") }

    assert_selector "span#netWorthFullscreenPeriod", text: "Last 30 days"
    assert_selector "[data-ds--dialog-target='content'].lg\\:max-w-\\[92vw\\]"
  end

  test "a header with only block content keeps the close button on its row" do
    dialog = DS::Dialog.new(variant: "drawer")
    render_inline(dialog) { dialog.with_header { "<span>Custom</span>".html_safe } }

    assert_selector "header > div > span", text: "Custom"
    assert_selector "header > div > button[data-action='DS--dialog#close']"
  end

  test "the close button is keyboard reachable and named" do
    dialog = DS::Dialog.new
    render_inline(dialog) { dialog.with_header(title: "Edit") }

    close = page.find("button[data-action='DS--dialog#close']")
    assert_equal I18n.t("ds.dialog.close"), close[:"aria-label"]
    assert_nil close[:tabindex]
  end

  test "custom_header leaves the close button out" do
    dialog = DS::Dialog.new
    render_inline(dialog) { dialog.with_header(title: "Edit", custom_header: true) }

    assert_no_selector "button[data-action='DS--dialog#close']"
  end

  test "click outside closes by default and can be turned off" do
    render_inline(DS::Dialog.new)
    assert_selector "dialog[data-ds--dialog-disable-click-outside-value='false']"
    assert_selector "dialog[data-action~='mousedown->DS--dialog#clickOutside']"

    render_inline(DS::Dialog.new(disable_click_outside: true))
    assert_selector "dialog[data-ds--dialog-disable-click-outside-value='true']"
  end

  test "the drawer keeps its phone insets" do
    render_inline(DS::Dialog.new(variant: "drawer"))

    classes = page.find("[data-ds--dialog-target='content']")[:class].split
    assert_includes classes, "mt-6"
    assert_includes classes, "max-h-[calc(100svh-1.75rem)]"
  end
end
