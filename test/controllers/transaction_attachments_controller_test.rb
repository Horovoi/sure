require "test_helper"

class TransactionAttachmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
    @transaction = @entry.transaction
  end

  test "uploads one file" do
    assert_difference -> { @transaction.attachments.count }, 1 do
      post transaction_attachments_path(@transaction), params: { attachments: [ pdf_upload ] }
    end

    assert_redirected_to transaction_path(@entry)
    assert_equal I18n.t("transaction_attachments.create.uploaded", count: 1), flash[:notice]
  end

  test "uploads several files and ignores the blank member of the multiple field" do
    assert_difference -> { @transaction.attachments.count }, 2 do
      post transaction_attachments_path(@transaction), params: { attachments: [ pdf_upload, "", image_upload ] }
    end

    assert_equal I18n.t("transaction_attachments.create.uploaded", count: 2), flash[:notice]
  end

  test "a signed blob id is not attached" do
    other_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.4 other"), filename: "other.pdf", content_type: "application/pdf")

    assert_no_difference -> { @transaction.attachments.count } do
      post transaction_attachments_path(@transaction), params: { attachments: [ other_blob.signed_id ] }
    end

    assert_equal I18n.t("transaction_attachments.create.no_files_selected"), flash[:alert]
  end

  test "no files gives an alert" do
    assert_no_difference -> { @transaction.attachments.count } do
      post transaction_attachments_path(@transaction), params: {}
    end

    assert_redirected_to transaction_path(@entry)
    assert_equal I18n.t("transaction_attachments.create.no_files_selected"), flash[:alert]
  end

  test "a file type that is not allowed is refused and nothing is saved" do
    assert_no_difference [ -> { @transaction.attachments.count }, -> { ActiveStorage::Blob.count } ] do
      post transaction_attachments_path(@transaction), params: { attachments: [ fixture_file_upload("notes.txt", "text/plain") ] }
    end

    assert_match "notes.txt", flash[:alert]
  end

  test "the file limit is enforced" do
    Transaction::MAX_ATTACHMENTS_PER_TRANSACTION.times { |i| attach_pdf(@transaction, "file#{i}.pdf") }

    assert_no_difference -> { @transaction.attachments.count } do
      post transaction_attachments_path(@transaction), params: { attachments: [ pdf_upload ] }
    end

    assert_equal I18n.t("transaction_attachments.create.too_many", count: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION), flash[:alert]
  end

  test "turbo stream upload replaces the section and shows a notice" do
    post transaction_attachments_path(@transaction), params: { attachments: [ pdf_upload ] }, as: :turbo_stream

    assert_response :success
    assert_match %(turbo-stream action="replace" target="#{ActionView::RecordIdentifier.dom_id(@transaction, :attachments)}"), response.body
    assert_match %(turbo-stream action="append" target="notification-tray"), response.body
    assert_match "receipt.pdf", response.body
  end

  test "show redirects to the blob inline or as a download" do
    attachment = attach_pdf(@transaction)

    get transaction_attachment_path(@transaction, attachment, disposition: :inline)
    assert_response :redirect
    assert_match "disposition=inline", response.location

    get transaction_attachment_path(@transaction, attachment, disposition: :attachment)
    assert_match "disposition=attachment", response.location
  end

  test "deletes a file" do
    attachment = attach_pdf(@transaction)

    assert_difference -> { @transaction.attachments.count }, -1 do
      delete transaction_attachment_path(@transaction, attachment), as: :turbo_stream
    end

    assert_response :success
    assert_match I18n.t("transaction_attachments.destroy.deleted"), response.body
  end

  test "another family's transaction is not found" do
    attachment = attach_pdf(@transaction)
    sign_in users(:empty)

    get transaction_attachment_path(@transaction, attachment)
    assert_response :not_found

    assert_no_difference -> { @transaction.attachments.count } do
      post transaction_attachments_path(@transaction), params: { attachments: [ pdf_upload ] }
      delete transaction_attachment_path(@transaction, attachment)
    end
  end

  test "the drawer shows the attachments section" do
    attach_pdf(@transaction)

    get transaction_path(@entry)

    assert_response :success
    assert_select "[data-testid='transaction-attachments']"
    assert_match "receipt.pdf", response.body
  end

  test "the transactions list filters by attachment and shows the chip" do
    attach_pdf(@transaction)

    get transactions_path(q: { attachment_status: [ "with" ] })

    assert_response :success
    assert_match I18n.t("transactions.searches.filters.badge.attachment_with"), response.body
    assert_select "##{ActionView::RecordIdentifier.dom_id(@entry)}"
    assert_select "input[name='q[attachment_status][]'][value='with'][checked]"
  end

  private
    def pdf_upload
      fixture_file_upload("receipt.pdf", "application/pdf")
    end

    def image_upload
      fixture_file_upload("square-placeholder.png", "image/png")
    end

    def attach_pdf(transaction, filename = "receipt.pdf")
      transaction.attachments.attach(io: file_fixture("receipt.pdf").open, filename: filename, content_type: "application/pdf")
      transaction.attachments.order(:created_at).last
    end
end
