require "application_system_test_case"

# w3-toolstrx transaction-attachments: attach a receipt in the drawer, open it, then
# find the transaction with the attachment filter.
class TransactionAttachmentsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    @account = accounts(:depository)
    @entry = @account.entries.create!(
      name: "Receipt purchase", date: Date.current, amount: 25, currency: "USD", entryable: Transaction.new
    )
    @other = @account.entries.create!(
      name: "No receipt purchase", date: Date.current, amount: 15, currency: "USD", entryable: Transaction.new
    )
  end

  test "attach a file in the drawer and open it" do
    visit transactions_url
    click_link @entry.name
    # The section starts closed while the transaction has no file; titles render uppercase
    find("summary", text: /\A#{Regexp.escape(I18n.t("transaction_attachments.section_title"))}\z/i).click

    within "[data-testid='transaction-attachments']" do
      assert_text I18n.t("transaction_attachments.attachments.empty")
      attach_file "attachments[]", file_fixture("receipt.pdf"), make_visible: true
      click_button I18n.t("transaction_attachments.attachments.upload_one")

      assert_text "receipt.pdf"
    end

    assert_text I18n.t("transaction_attachments.create.uploaded", count: 1)
    assert_equal 1, @entry.transaction.attachments.count

    view_label = I18n.t("transaction_attachments.attachments.view", filename: "receipt.pdf")
    receipt_window = window_opened_by { find("a[aria-label='#{view_label}']").click }
    within_window(receipt_window) do
      assert_match %r{/rails/active_storage/}, current_url
    end
  end

  test "the attachment filter lists only transactions with a file" do
    @entry.transaction.attachments.attach(io: file_fixture("receipt.pdf").open, filename: "receipt.pdf", content_type: "application/pdf")

    visit transactions_url
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button I18n.t("transactions.search.filters.attachment")
      check I18n.t("transactions.searches.filters.attachment_filter.with")
      click_button I18n.t("transactions.searches.menu.apply")
    end

    assert_text I18n.t("transactions.searches.filters.badge.attachment_with")
    assert_selector "#" + dom_id(@entry)
    assert_no_selector "#" + dom_id(@other)
  end
end
