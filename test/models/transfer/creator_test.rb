require "test_helper"

class Transfer::CreatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @source_account = accounts(:depository)
    @destination_account = accounts(:investment)
    @date = Date.current
    @amount = 100
    # Ensure the Investment Contributions category exists for transfer tests
    @investment_category = ensure_investment_contributions_category(@family)
  end

  test "creates investment contribution when transferring from depository to investment" do
    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: @destination_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert_equal "confirmed", transfer.status

    # Verify outflow transaction is marked as investment_contribution
    outflow = transfer.outflow_transaction
    assert_equal "investment_contribution", outflow.kind
    assert_equal @amount, outflow.entry.amount
    assert_equal @source_account.currency, outflow.entry.currency
    assert_equal "Transfer to #{@destination_account.name}", outflow.entry.name
    assert_equal @investment_category, outflow.category, "Should auto-assign Investment Contributions category"

    # Verify inflow transaction (always funds_movement)
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal(@amount * -1, inflow.entry.amount)
    assert_equal @destination_account.currency, inflow.entry.currency
    assert_equal "Transfer from #{@source_account.name}", inflow.entry.name
  end

  test "creates basic transfer between depository accounts" do
    other_depository = @family.accounts.create!(name: "Savings", balance: 1000, currency: "USD", accountable: Depository.new)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: other_depository.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert_equal "confirmed", transfer.status
    assert transfer.regular_transfer?
    assert_equal "transfer", transfer.transfer_type

    # Verify outflow transaction (depository to depository = funds_movement)
    outflow = transfer.outflow_transaction
    assert_equal "funds_movement", outflow.kind
    assert_nil outflow.category, "Should NOT auto-assign category for regular transfers"

    # Verify inflow transaction
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
  end

  test "creates investment contribution when transferring from depository to crypto" do
    crypto_account = accounts(:crypto)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: crypto_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?

    # Verify outflow transaction is investment_contribution (not funds_movement)
    outflow = transfer.outflow_transaction
    assert_equal "investment_contribution", outflow.kind
    assert_equal "Transfer to #{crypto_account.name}", outflow.entry.name
    assert_equal @investment_category, outflow.category

    # Verify inflow transaction with currency handling
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal "Transfer from #{@source_account.name}", inflow.entry.name
    assert_equal crypto_account.currency, inflow.entry.currency
  end

  test "creates funds_movement for investment to investment transfer (rollover)" do
    # Rollover case: investment → investment should stay as funds_movement
    other_investment = @family.accounts.create!(name: "IRA", balance: 5000, currency: "USD", accountable: Investment.new)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @destination_account.id, # investment account
      destination_account_id: other_investment.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?

    # Verify outflow is funds_movement (NOT investment_contribution for rollovers)
    outflow = transfer.outflow_transaction
    assert_equal "funds_movement", outflow.kind
    assert_nil outflow.category, "Should NOT auto-assign category for investment→investment transfers"

    # Verify inflow
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
  end

  test "creates loan payment" do
    loan_account = accounts(:loan)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: loan_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert transfer.loan_payment?
    assert_equal "loan_payment", transfer.transfer_type

    # Verify outflow transaction is marked as loan payment
    outflow = transfer.outflow_transaction
    assert_equal "loan_payment", outflow.kind
    assert_equal "Payment to #{loan_account.name}", outflow.entry.name

    # Verify inflow transaction
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal "Payment from #{@source_account.name}", inflow.entry.name
  end

  test "creates credit card payment" do
    credit_card_account = accounts(:credit_card)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: credit_card_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert transfer.liability_payment?
    assert_equal "liability_payment", transfer.transfer_type

    # Verify outflow transaction is marked as payment for liability
    outflow = transfer.outflow_transaction
    assert_equal "cc_payment", outflow.kind
    assert_equal "Payment to #{credit_card_account.name}", outflow.entry.name

    # Verify inflow transaction
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal "Payment from #{@source_account.name}", inflow.entry.name
  end

  test "raises error when source account ID is invalid" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: @family,
        source_account_id: 99999,
        destination_account_id: @destination_account.id,
        date: @date,
        amount: @amount
      )
    end
  end

  test "raises error when destination account ID is invalid" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: @family,
        source_account_id: @source_account.id,
        destination_account_id: 99999,
        date: @date,
        amount: @amount
      )
    end
  end

  test "raises error when source account belongs to different family" do
    other_family = families(:empty)

    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: other_family,
        source_account_id: @source_account.id,
        destination_account_id: @destination_account.id,
        date: @date,
        amount: @amount
      )
    end
  end

  test "a transfer between currencies with no exchange rate is a validation error, not a 1:1 transfer" do
    pln_account = @family.accounts.create!(name: "PLN cash", balance: 0, currency: "PLN", accountable: Depository.new)

    transfer = nil
    assert_no_difference [ "Transfer.count", "Entry.count" ] do
      transfer = Transfer::Creator.new(
        family: @family,
        source_account_id: @source_account.id,
        destination_account_id: pln_account.id,
        date: @date,
        amount: @amount
      ).create
    end

    assert_not transfer.persisted?
    assert_includes transfer.errors.full_messages.to_sentence, "No exchange rate from USD to PLN"
  end

  test "a transfer between currencies converts at the nearest stored rate" do
    pln_account = @family.accounts.create!(name: "PLN cash", balance: 0, currency: "PLN", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "USD", to_currency: "PLN", date: @date - 15.days, rate: 4)

    transfer = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: pln_account.id,
      date: @date,
      amount: @amount
    ).create

    assert transfer.persisted?
    assert_equal(-400, transfer.inflow_transaction.entry.amount)
  end

  # w2-transfers custom-exchange-rate
  test "a transfer between currencies uses the user's rate instead of the stored one" do
    uah_account = @family.accounts.create!(name: "UAH card", balance: 0, currency: "UAH", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "UAH", to_currency: "USD", date: @date, rate: 0.025)

    transfer = Transfer::Creator.new(
      family: @family,
      source_account_id: uah_account.id,
      destination_account_id: @source_account.id,
      date: @date,
      amount: 4_150,
      exchange_rate: "0.024"
    ).create

    assert transfer.persisted?
    assert_equal 4_150, transfer.outflow_transaction.entry.amount
    assert_equal "UAH", transfer.outflow_transaction.entry.currency
    assert_equal BigDecimal("-99.6"), transfer.inflow_transaction.entry.amount
    assert_equal "USD", transfer.inflow_transaction.entry.currency
  end

  test "a transfer between currencies takes the destination amount exactly" do
    uah_account = @family.accounts.create!(name: "UAH card", balance: 0, currency: "UAH", accountable: Depository.new)

    # No stored rate at all: the received amount alone is enough
    transfer = Transfer::Creator.new(
      family: @family,
      source_account_id: uah_account.id,
      destination_account_id: @source_account.id,
      date: @date,
      amount: 4_150,
      destination_amount: "100"
    ).create

    assert transfer.persisted?
    assert_equal(-100, transfer.inflow_transaction.entry.amount)
    assert_equal 4_150, transfer.outflow_transaction.entry.amount
  end

  test "a rate or destination amount that is not above zero is a validation error" do
    uah_account = @family.accounts.create!(name: "UAH card", balance: 0, currency: "UAH", accountable: Depository.new)

    [ { exchange_rate: "0" }, { exchange_rate: "abc" }, { destination_amount: "-5" }, { exchange_rate: "1", destination_amount: "2" } ].each do |options|
      transfer = nil
      assert_no_difference [ "Transfer.count", "Entry.count" ] do
        transfer = Transfer::Creator.new(
          family: @family, source_account_id: uah_account.id, destination_account_id: @source_account.id,
          date: @date, amount: 100, **options
        ).create
      end

      assert_not transfer.persisted?, options.inspect
      assert transfer.errors[:base].any?, options.inspect
    end
  end

  test "a rate given for two accounts in one currency is ignored" do
    other_depository = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)

    transfer = Transfer::Creator.new(
      family: @family, source_account_id: @source_account.id, destination_account_id: other_depository.id,
      date: @date, amount: 100, exchange_rate: "2", destination_amount: "300"
    ).create

    assert transfer.persisted?
    assert_equal(-100, transfer.inflow_transaction.entry.amount)
  end

  test "a zero amount is a validation error" do
    other_depository = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)

    transfer = Transfer::Creator.new(
      family: @family, source_account_id: @source_account.id, destination_account_id: other_depository.id,
      date: @date, amount: 0
    ).create

    assert_not transfer.persisted?
    assert_includes transfer.errors.full_messages.to_sentence, "Amount must be greater than 0"
  end

  # w2-transfers transfer-fees
  test "fees on each side become linked expenses in Fees and the legs keep the principal" do
    uah_account = @family.accounts.create!(name: "UAH card", balance: 0, currency: "UAH", accountable: Depository.new)

    transfer = nil
    assert_difference -> { Entry.count } => 4, -> { Transfer.count } => 1 do
      transfer = Transfer::Creator.new(
        family: @family,
        source_account_id: uah_account.id,
        destination_account_id: @source_account.id,
        date: @date,
        amount: 4_150,
        destination_amount: "100",
        source_fee: "41,50",
        destination_fee: "1.5"
      ).create
    end

    assert transfer.persisted?
    assert_equal 4_150, transfer.outflow_transaction.entry.amount
    assert_equal(-100, transfer.inflow_transaction.entry.amount)

    source_fee = transfer.fee_transactions_for(:source).sole
    assert_equal uah_account, source_fee.entry.account
    assert_equal BigDecimal("41.5"), source_fee.entry.amount
    assert_equal "UAH", source_fee.entry.currency
    assert_equal "Fees", source_fee.category.name
    assert_equal "standard", source_fee.kind
    assert_equal @date, source_fee.entry.date

    destination_fee = transfer.fee_transactions_for(:destination).sole
    assert_equal @source_account, destination_fee.entry.account
    assert_equal BigDecimal("1.5"), destination_fee.entry.amount
    assert_equal "USD", destination_fee.entry.currency
    assert_equal source_fee.category, destination_fee.category
  end

  test "a negative or unreadable fee is a validation error and nothing is saved" do
    other_depository = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)

    [ { source_fee: "-1" }, { destination_fee: "abc" } ].each do |options|
      transfer = nil
      assert_no_difference [ "Transfer.count", "Entry.count" ] do
        transfer = Transfer::Creator.new(
          family: @family, source_account_id: @source_account.id, destination_account_id: other_depository.id,
          date: @date, amount: 100, **options
        ).create
      end

      assert_includes transfer.errors.full_messages.to_sentence, "Fees must be numbers", options.inspect
    end
  end

  test "a zero fee creates no fee expense" do
    other_depository = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)

    assert_difference -> { Entry.count } => 2 do
      Transfer::Creator.new(
        family: @family, source_account_id: @source_account.id, destination_account_id: other_depository.id,
        date: @date, amount: 100, source_fee: "0", destination_fee: ""
      ).create
    end
  end
end
