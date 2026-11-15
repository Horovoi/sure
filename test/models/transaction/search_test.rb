require "test_helper"

class Transaction::SearchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @checking_account = accounts(:depository)
    @credit_card_account = accounts(:credit_card)
    @loan_account = accounts(:loan)

    # Clean up existing entries/transactions from fixtures to ensure test isolation
    @family.accounts.each { |account| account.entries.delete_all }
  end

  test "search filters by transaction types using kind enum" do
    # Create different types of transactions using the helper method
    standard_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    transfer_entry = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "funds_movement"
    )

    payment_entry = create_transaction(
      account: @credit_card_account,
      amount: -300,
      kind: "cc_payment"
    )

    loan_payment_entry = create_transaction(
      account: @loan_account,
      amount: 400,
      kind: "loan_payment"
    )

    one_time_entry = create_transaction(
      account: @checking_account,
      amount: 500,
      kind: "one_time"
    )

    # Test transfer type filter (includes loan_payment)
    transfer_results = Transaction::Search.new(@family, filters: { types: [ "transfer" ] }).transactions_scope
    transfer_ids = transfer_results.pluck(:id)

    assert_includes transfer_ids, transfer_entry.entryable.id
    assert_includes transfer_ids, payment_entry.entryable.id
    assert_includes transfer_ids, loan_payment_entry.entryable.id
    assert_not_includes transfer_ids, one_time_entry.entryable.id
    assert_not_includes transfer_ids, standard_entry.entryable.id

    # Test expense type filter (excludes transfer kinds but includes one_time)
    expense_results = Transaction::Search.new(@family, filters: { types: [ "expense" ] }).transactions_scope
    expense_ids = expense_results.pluck(:id)

    assert_includes expense_ids, standard_entry.entryable.id
    assert_includes expense_ids, one_time_entry.entryable.id
    assert_not_includes expense_ids, loan_payment_entry.entryable.id
    assert_not_includes expense_ids, transfer_entry.entryable.id
    assert_not_includes expense_ids, payment_entry.entryable.id

    # Test income type filter
    income_entry = create_transaction(
      account: @checking_account,
      amount: -600,
      kind: "standard"
    )

    income_results = Transaction::Search.new(@family, filters: { types: [ "income" ] }).transactions_scope
    income_ids = income_results.pluck(:id)

    assert_includes income_ids, income_entry.entryable.id
    assert_not_includes income_ids, standard_entry.entryable.id
    assert_not_includes income_ids, loan_payment_entry.entryable.id
    assert_not_includes income_ids, transfer_entry.entryable.id

    # Test combined expense and income filter (excludes transfer kinds but includes one_time)
    non_transfer_results = Transaction::Search.new(@family, filters: { types: [ "expense", "income" ] }).transactions_scope
    non_transfer_ids = non_transfer_results.pluck(:id)

    assert_includes non_transfer_ids, standard_entry.entryable.id
    assert_includes non_transfer_ids, income_entry.entryable.id
    assert_includes non_transfer_ids, one_time_entry.entryable.id
    assert_not_includes non_transfer_ids, loan_payment_entry.entryable.id
    assert_not_includes non_transfer_ids, transfer_entry.entryable.id
    assert_not_includes non_transfer_ids, payment_entry.entryable.id
  end

  test "search category filter handles uncategorized transactions correctly with kind filtering" do
    # Create uncategorized transactions of different kinds
    uncategorized_standard = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard"
    )

    uncategorized_transfer = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "funds_movement"
    )

    uncategorized_loan_payment = create_transaction(
      account: @loan_account,
      amount: 300,
      kind: "loan_payment"
    )

    # Search for uncategorized transactions
    uncategorized_results = Transaction::Search.new(@family, filters: { categories: [ Category.uncategorized.name ] }).transactions_scope
    uncategorized_ids = uncategorized_results.pluck(:id)

    # Should include standard uncategorized transactions
    assert_includes uncategorized_ids, uncategorized_standard.entryable.id
    # Should include loan_payment since it's treated specially in category logic
    assert_includes uncategorized_ids, uncategorized_loan_payment.entryable.id

    # Should exclude transfer transactions even if uncategorized
    assert_not_includes uncategorized_ids, uncategorized_transfer.entryable.id
  end

  test "the Uncategorized sentinel and the display name both filter for no category" do
    uncategorized = create_transaction(account: @checking_account, amount: 100, kind: "standard")
    categorized = create_transaction(account: @checking_account, amount: 50, category: categories(:food_and_drink))
    transfer = create_transaction(account: @checking_account, amount: 200, kind: "funds_movement")

    [ Category::UNCATEGORIZED_FILTER_VALUE, Category.uncategorized.name ].each do |value|
      ids = Transaction::Search.new(@family, filters: { categories: [ value ] }).transactions_scope.pluck(:id)

      assert_includes ids, uncategorized.entryable.id, value
      assert_not_includes ids, categorized.entryable.id, value
      assert_not_includes ids, transfer.entryable.id, value
    end
  end

  test "the Uncategorized sentinel combines with a named category" do
    uncategorized = create_transaction(account: @checking_account, amount: 100)
    categorized = create_transaction(account: @checking_account, amount: 50, category: categories(:food_and_drink))

    ids = Transaction::Search.new(@family, filters: { categories: [ Category::UNCATEGORIZED_FILTER_VALUE, categories(:food_and_drink).name ] })
      .transactions_scope.pluck(:id)

    assert_includes ids, uncategorized.entryable.id
    assert_includes ids, categorized.entryable.id
  end

  test "new family-based API works correctly" do
    # Create transactions for testing
    transaction1 = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    transaction2 = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "funds_movement"
    )

    # Test new family-based API
    search = Transaction::Search.new(@family, filters: { types: [ "expense" ] })
    results = search.transactions_scope
    result_ids = results.pluck(:id)

    # Should include expense transactions
    assert_includes result_ids, transaction1.entryable.id
    # Should exclude transfer transactions
    assert_not_includes result_ids, transaction2.entryable.id

    # Test that the relation builds from family.transactions correctly
    assert_equal @family.transactions.joins(entry: :account).where(
      "entries.amount >= 0 AND NOT (transactions.kind IN ('funds_movement', 'cc_payment', 'loan_payment'))"
    ).count, results.count
  end

  test "family-based API requires family parameter" do
    assert_raises(NoMethodError) do
      search = Transaction::Search.new({ types: [ "expense" ] })
      search.transactions_scope  # This will fail when trying to call .transactions on a Hash
    end
  end

  # Totals method tests (lifted from Transaction::TotalsTest)

  test "totals computes basic expense and income totals" do
    # Create expense transaction
    expense_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    # Create income transaction
    income_entry = create_transaction(
      account: @checking_account,
      amount: -200,
      kind: "standard"
    )

    search = Transaction::Search.new(@family)
    totals = search.totals

    assert_equal 2, totals.count
    assert_equal Money.new(100, "USD"), totals.expense_money # $100
    assert_equal Money.new(200, "USD"), totals.income_money  # $200
  end

  test "totals leave out excluded transactions, like the income statement" do
    create_transaction(account: @checking_account, amount: 100, kind: "standard")
    create_transaction(account: @checking_account, amount: 40, kind: "standard", excluded: true)
    create_transaction(account: @checking_account, amount: -70, kind: "standard", excluded: true)

    totals = Transaction::Search.new(@family).totals

    assert_equal 3, totals.count
    assert_equal Money.new(100, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "totals handles multi-currency transactions with exchange rates" do
    # Create EUR transaction
    eur_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      currency: "EUR",
      kind: "standard"
    )

    # Create exchange rate EUR -> USD
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      rate: 1.1,
      date: eur_entry.date
    )

    # Create USD transaction
    usd_entry = create_transaction(
      account: @checking_account,
      amount: 50,
      currency: "USD",
      kind: "standard"
    )

    search = Transaction::Search.new(@family)
    totals = search.totals

    assert_equal 2, totals.count
    # EUR 100 * 1.1 + USD 50 = 110 + 50 = 160
    assert_equal Money.new(160, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "totals leave out an amount whose currency has no exchange rate" do
    create_transaction(account: @checking_account, amount: 100, currency: "EUR", kind: "standard")
    create_transaction(account: @checking_account, amount: 50, currency: "USD", kind: "standard")

    totals = Transaction::Search.new(@family).totals

    assert_equal 2, totals.count
    # The EUR 100 is left out, never counted at 1
    assert_equal Money.new(50, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "totals convert at the nearest stored rate when the day has none" do
    create_transaction(account: @checking_account, amount: 100, currency: "EUR", kind: "standard", date: Date.current)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.5, date: 20.days.ago.to_date)

    assert_equal Money.new(150, "USD"), Transaction::Search.new(@family).totals.expense_money
  end

  test "totals respects category filters" do
    # Create transactions in different categories
    food_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    other_entry = create_transaction(
      account: @checking_account,
      amount: 50,
      category: categories(:income),
      kind: "standard"
    )

    # Filter by food category only
    search = Transaction::Search.new(@family, filters: { categories: [ "Food & Drink" ] })
    totals = search.totals

    assert_equal 1, totals.count
    assert_equal Money.new(100, "USD"), totals.expense_money # Only food transaction
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "category filter includes subcategories" do
    # Create a transaction with the parent category
    parent_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    # Create a transaction with the subcategory (fixture :subcategory has name "Restaurants", parent "Food & Drink")
    subcategory_entry = create_transaction(
      account: @checking_account,
      amount: 75,
      category: categories(:subcategory),
      kind: "standard"
    )

    # Create a transaction with a different category
    other_entry = create_transaction(
      account: @checking_account,
      amount: 50,
      category: categories(:income),
      kind: "standard"
    )

    # Filter by parent category only - should include both parent and subcategory transactions
    search = Transaction::Search.new(@family, filters: { categories: [ "Food & Drink" ] })
    results = search.transactions_scope
    result_ids = results.pluck(:id)

    # Should include both parent and subcategory transactions
    assert_includes result_ids, parent_entry.entryable.id
    assert_includes result_ids, subcategory_entry.entryable.id
    # Should not include transactions with different category
    assert_not_includes result_ids, other_entry.entryable.id

    # Verify totals also include subcategory transactions
    totals = search.totals
    assert_equal 2, totals.count
    assert_equal Money.new(175, "USD"), totals.expense_money # 100 + 75
  end

  test "totals respects type filters" do
    # Create expense and income transactions
    expense_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard"
    )

    income_entry = create_transaction(
      account: @checking_account,
      amount: -200,
      kind: "standard"
    )

    # Filter by expense type only
    search = Transaction::Search.new(@family, filters: { types: [ "expense" ] })
    totals = search.totals

    assert_equal 1, totals.count
    assert_equal Money.new(100, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "totals handles empty results" do
    search = Transaction::Search.new(@family)
    totals = search.totals

    assert_equal 0, totals.count
    assert_equal Money.new(0, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "category filter handles non-existent category names without SQL error" do
    # Create a transaction with an existing category
    existing_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    # Search for non-existent category names (parent_category_ids will be empty)
    # This should not cause a SQL error with "IN ()"
    search = Transaction::Search.new(@family, filters: { categories: [ "Non-Existent Category 1", "Non-Existent Category 2" ] })
    results = search.transactions_scope
    result_ids = results.pluck(:id)

    # Should not include any transactions since categories don't exist
    assert_not_includes result_ids, existing_entry.entryable.id
    assert_equal 0, result_ids.length

    # Verify totals also work without error
    totals = search.totals
    assert_equal 0, totals.count
    assert_equal Money.new(0, "USD"), totals.expense_money
  end

  test "search matches entries name OR notes with ILIKE" do
    # Transaction with matching text in name only
    name_match = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard",
      name: "Grocery Store"
    )

    # Transaction with matching text in notes only
    notes_match = create_transaction(
      account: @checking_account,
      amount: 50,
      kind: "standard",
      name: "Credit Card Payment",
      notes: "Payment of 50 USD at Grocery Mart on 2026-11-01"
    )

    # Transaction with no matching text
    no_match = create_transaction(
      account: @checking_account,
      amount: 75,
      kind: "standard",
      name: "Gas station",
      notes: "Fuel refill"
    )

    search = Transaction::Search.new(
      @family,
      filters: { search: "grocery" }
    )

    results = search.transactions_scope
    result_ids = results.pluck(:id)

    # Should match name
    assert_includes result_ids, name_match.entryable.id

    # Should match notes
    assert_includes result_ids, notes_match.entryable.id

    # Should not match unrelated transactions
    assert_not_includes result_ids, no_match.entryable.id
  end

  test "tag filter matches transactions with any of the filtered tags, once each" do
    tag_a = @family.tags.create!(name: "TagA")
    tag_b = @family.tags.create!(name: "TagB")
    tag_c = @family.tags.create!(name: "TagC")

    double_tagged = create_transaction(account: @checking_account, amount: 100, kind: "standard", tags: [ tag_a, tag_b ])
    single_tagged = create_transaction(account: @checking_account, amount: 50, kind: "standard", tags: [ tag_a ])
    unrelated = create_transaction(account: @checking_account, amount: 75, kind: "standard", tags: [ tag_c ])

    result_ids = Transaction::Search.new(@family, filters: { tags: [ "TagA", "TagB" ] }).transactions_scope.pluck(:id)

    assert_equal [ double_tagged.entryable.id, single_tagged.entryable.id ].sort, result_ids.sort
    assert_not_includes result_ids, unrelated.entryable.id
  end

  test "totals count and sum a transaction with two filtered tags once" do
    tag_a = @family.tags.create!(name: "FanA")
    tag_b = @family.tags.create!(name: "FanB")

    create_transaction(account: @checking_account, amount: 100, kind: "standard", tags: [ tag_a, tag_b ])
    create_transaction(account: @checking_account, amount: 50, kind: "standard", tags: [ tag_a ])

    search = Transaction::Search.new(@family, filters: { tags: [ "FanA", "FanB" ] })

    assert_equal 2, search.transactions_scope.count
    assert_equal 2, search.totals.count
    assert_equal Money.new(150, @family.currency), search.totals.expense_money
  end

  # --- w3-toolstrx filter-options: No merchant, Untagged ----------------------------------------------------------

  test "the Uncategorized filter leaves out only transfer legs, the kinds the categorize wizard skips" do
    one_time = create_transaction(account: @checking_account, amount: 40, kind: "one_time")
    cc_payment = create_transaction(account: @checking_account, amount: 60, kind: "cc_payment")

    ids = Transaction::Search.new(@family, filters: { categories: [ Category::UNCATEGORIZED_FILTER_VALUE ] }).transactions_scope.pluck(:id)

    assert_includes ids, one_time.entryable.id
    assert_not_includes ids, cc_payment.entryable.id
  end

  test "No merchant finds transactions without a merchant" do
    with_merchant = create_transaction(account: @checking_account, amount: 10, merchant: merchants(:netflix))
    without = create_transaction(account: @checking_account, amount: 20)

    ids = Transaction::Search.new(@family, filters: { merchants: [ Merchant::NO_MERCHANT_FILTER_VALUE ] }).transactions_scope.pluck(:id)

    assert_equal [ without.entryable.id ], ids
    assert_not_includes ids, with_merchant.entryable.id
  end

  test "No merchant combines with a named merchant" do
    netflix = create_transaction(account: @checking_account, amount: 10, merchant: merchants(:netflix))
    amazon = create_transaction(account: @checking_account, amount: 15, merchant: merchants(:amazon))
    without = create_transaction(account: @checking_account, amount: 20)

    search = Transaction::Search.new(@family, filters: { merchants: [ Merchant::NO_MERCHANT_FILTER_VALUE, merchants(:netflix).name ] })
    ids = search.transactions_scope.pluck(:id)

    assert_equal [ netflix.entryable.id, without.entryable.id ].sort, ids.sort
    assert_not_includes ids, amazon.entryable.id
    assert_equal 2, search.totals.count
  end

  test "Untagged finds transactions without a tag" do
    tag = @family.tags.create!(name: "Trip")
    tagged = create_transaction(account: @checking_account, amount: 10, tags: [ tag ])
    untagged = create_transaction(account: @checking_account, amount: 20)

    ids = Transaction::Search.new(@family, filters: { tags: [ Tag::UNTAGGED_FILTER_VALUE ] }).transactions_scope.pluck(:id)

    assert_equal [ untagged.entryable.id ], ids
    assert_not_includes ids, tagged.entryable.id
  end

  test "Untagged combines with named tags, and a transaction with two of them counts once" do
    tag_a = @family.tags.create!(name: "UntagA")
    tag_b = @family.tags.create!(name: "UntagB")
    tag_c = @family.tags.create!(name: "UntagC")

    double = create_transaction(account: @checking_account, amount: 100, tags: [ tag_a, tag_b ])
    untagged = create_transaction(account: @checking_account, amount: 50)
    other = create_transaction(account: @checking_account, amount: 70, tags: [ tag_c ])

    search = Transaction::Search.new(@family, filters: { tags: [ Tag::UNTAGGED_FILTER_VALUE, "UntagA", "UntagB" ] })
    ids = search.transactions_scope.pluck(:id)

    assert_equal [ double.entryable.id, untagged.entryable.id ].sort, ids.sort
    assert_not_includes ids, other.entryable.id
    assert_equal 2, search.totals.count
    assert_equal Money.new(150, @family.currency), search.totals.expense_money
  end

  test "a real merchant or tag cannot take the filter sentinel as its name" do
    assert_not @family.tags.new(name: Tag::UNTAGGED_FILTER_VALUE).valid?
    assert_not @family.merchants.new(name: Merchant::NO_MERCHANT_FILTER_VALUE, color: "#000000").valid?
  end

  test "the synthetic options submit the sentinel and show the English name" do
    assert_equal Merchant::NO_MERCHANT_FILTER_VALUE, Merchant.no_merchant.filter_value
    assert_equal "No merchant", Merchant.no_merchant.name
    assert_equal Tag::UNTAGGED_FILTER_VALUE, Tag.untagged.filter_value
    assert_equal "Untagged", Tag.untagged.name
    assert_equal merchants(:netflix).name, merchants(:netflix).filter_value
  end
end
