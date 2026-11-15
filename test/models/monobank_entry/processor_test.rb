require "test_helper"

class MonobankEntry::ProcessorTest < ActiveSupport::TestCase
  include MonobankTestHelper

  setup do
    setup_monobank_family
    @product = create_monobank_product(account_id: "card")
    @account = @item.create_linked_account!(monobank_account: @product, accountable_type: "Depository")
  end

  def processor(row, **options)
    MonobankEntry::Processor.new(row, monobank_account: @product.reload, **options)
  end

  test "canonical ids: the monobank id, or a content hash for a row without one" do
    assert_equal "monobank_abc", MonobankEntry::Processor.canonical_external_id({ "id" => "abc" })

    hashed = MonobankEntry::Processor.canonical_external_id({ "time" => 1, "amount" => -5, "description" => "x" })
    assert_match(/\Amonobank_pending_\h{32}\z/, hashed)
    assert_equal hashed, MonobankEntry::Processor.canonical_external_id({ time: 1, amount: -5, description: "x" })
  end

  test "pending? reads hold" do
    assert MonobankEntry::Processor.pending?({ "hold" => true })
    assert MonobankEntry::Processor.pending?({ hold: "true" })
    assert_not MonobankEntry::Processor.pending?({ "hold" => false })
    assert_not MonobankEntry::Processor.pending?(nil)
  end

  test "passes claim, MCC category and cutover through to the import adapter" do
    adapter = mock("adapter")
    claimed = Entry.new
    adapter.stubs(:find_or_create_merchant).returns(nil)
    adapter.expects(:import_transaction).with do |args|
      args[:claimed_entry].equal?(claimed) && args[:category_id_if_blank] == "cat-1" &&
        args[:cutover_date] == Date.new(2026, 11, 14) && args[:source] == "monobank" && args[:amount] == BigDecimal("12.34")
    end.returns(:entry)

    result = processor(monobank_row(id: "x", time: Time.current, amount: -1_234), import_adapter: adapter, claimed_entry: claimed,
                       category_id_if_blank: "cat-1", cutover_date: Date.new(2026, 11, 14)).process

    assert_equal :entry, result
  end

  test "a row without a time is invalid" do
    assert_raises(ArgumentError) { processor({ "id" => "x", "amount" => -1 }).date }
  end

  test "nil for an unlinked product" do
    other = create_monobank_product(account_id: "other")
    assert_nil MonobankEntry::Processor.new(monobank_row(id: "x", time: Time.current, amount: -1), monobank_account: other).process
  end
end
