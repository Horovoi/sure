require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "#title(page_title)" do
    title("Test Title")
    assert_equal "Test Title", content_for(:title)
  end

  test "#header_title(page_title)" do
    header_title("Test Header Title")
    assert_equal "Test Header Title", content_for(:header_title)
  end

  def setup
    @account1 = Account.new(currency: "USD", balance: 1)
    @account2 = Account.new(currency: "USD", balance: 2)
    @account3 = Account.new(currency: "EUR", balance: -7)
  end

  test "#totals_by_currency(collection: collection, money_method: money_method)" do
    assert_equal "$3.00", totals_by_currency(collection: [ @account1, @account2 ], money_method: :balance_money)
    assert_equal "$3.00 | -€7.00", totals_by_currency(collection: [ @account1, @account2, @account3 ], money_method: :balance_money)
    assert_equal "", totals_by_currency(collection: [], money_method: :balance_money)
    assert_equal "$0.00", totals_by_currency(collection: [ Account.new(currency: "USD", balance: 0) ], money_method: :balance_money)
    assert_equal "-$3.00 | €7.00", totals_by_currency(collection: [ @account1, @account2, @account3 ], money_method: :balance_money, negate: true)
  end

  # --- Enabled currencies (w1-ds money field) ---

  test "currency picker options are every currency without a family" do
    assert_equal Money::Currency.as_options.map(&:iso_code), currency_picker_options_for_family(nil)
  end

  test "currency picker options are the family's currencies plus the record's own" do
    family = families(:dylan_family)
    family.update!(currency: "UAH", enabled_currencies: [ "UAH", "USD" ])

    assert_equal [ "UAH", "USD", "EUR" ], currency_picker_options_for_family(family, extra: "EUR")
  end

  test "currency_label names the currency and its code" do
    assert_equal "Ukrainian Hryvnia (UAH)", currency_label("UAH")
  end

  # w2-transfers transfer-form-fixes (upstream ea326e1c9)
  test "a day with only transfers totals zero in its own currency" do
    entries = Transaction::TRANSFER_KINDS.map { |kind| Entry.new(currency: "GBP", amount: 100, entryable: Transaction.new(kind: kind)) }

    assert_equal "£0.00", totals_by_currency(collection: entries, money_method: :amount_money)
    assert_equal "£0.00", totals_by_currency(collection: entries, money_method: :amount_money, negate: true)
  end
end
