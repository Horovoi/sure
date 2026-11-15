require "test_helper"

class TransactionAttachmentTest < ActiveSupport::TestCase
  setup do
    @transaction = transactions(:one)
  end

  test "a pdf or an image is accepted" do
    @transaction.attachments.attach(io: file_fixture("receipt.pdf").open, filename: "receipt.pdf", content_type: "application/pdf")
    @transaction.attachments.attach(io: file_fixture("square-placeholder.png").open, filename: "photo.png", content_type: "image/png")

    assert @transaction.valid?
    assert_equal 2, @transaction.attachments.count
  end

  test "a type that is not allowed is refused" do
    @transaction.attachments.attach(io: file_fixture("notes.txt").open, filename: "notes.txt", content_type: "text/plain")

    assert_not @transaction.valid?
    assert_match "notes.txt", @transaction.errors.where(:attachments).map(&:message).join
  end

  test "the type is read from the file's bytes when they show one" do
    @transaction.attachments.attach(io: file_fixture("square-placeholder.png").open, filename: "photo.exe", content_type: "application/x-msdownload")

    assert_equal "image/png", @transaction.attachments.last.content_type
    assert @transaction.valid?
  end

  test "more than the limit is refused" do
    (Transaction::MAX_ATTACHMENTS_PER_TRANSACTION + 1).times do |i|
      @transaction.attachments.attach(io: file_fixture("receipt.pdf").open, filename: "file#{i}.pdf", content_type: "application/pdf")
    end

    assert_not @transaction.valid?
    assert @transaction.errors.of_kind?(:attachments, :too_many)
  end

  test "a file over the size limit is refused" do
    large = StringIO.new("%PDF-1.4\n" + ("x" * Transaction::MAX_ATTACHMENT_SIZE))
    @transaction.attachments.attach(io: large, filename: "large.pdf", content_type: "application/pdf")

    assert_not @transaction.valid?
    assert @transaction.errors.of_kind?(:attachments, :too_large)
  end

  test "the files go with the transaction" do
    @transaction.attachments.attach(io: file_fixture("receipt.pdf").open, filename: "receipt.pdf", content_type: "application/pdf")

    assert_difference -> { ActiveStorage::Attachment.where(record: @transaction).count }, -1 do
      @transaction.entry.destroy!
    end
  end
end
