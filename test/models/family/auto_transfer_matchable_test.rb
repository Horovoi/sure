require "test_helper"

class Family::AutoTransferMatchableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @depository = accounts(:depository)
    @credit_card = accounts(:credit_card)
  end

  test "auto-matches transfers" do
    outflow_entry = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
  end

  test "auto-matches multi-currency transfers on a confirmed route" do
    load_exchange_prices
    confirm_route!(from: @depository, to: @credit_card)
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    # test match within lower 5% bound
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1330, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    # test match within upper 5% bound
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1500)
    create_transaction(date: Date.current, account: @credit_card, amount: -2189, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    # test no match outside of slippage tolerance
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 1000)
    create_transaction(date: Date.current, account: @credit_card, amount: -1320, currency: "CAD")

    assert_difference -> { Transfer.count } => 0 do
      @family.auto_match_transfers!
    end
  end

  test "only matches inflow with correct currency when duplicate amounts exist" do
    load_exchange_prices
    confirm_route!(from: @depository, to: @credit_card)
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500, currency: "CAD")
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
  end

  # In this scenario, our matching logic should find 4 potential matches.  These matches should be ranked based on
  # days apart, then de-duplicated so that we aren't auto-matching the same transaction across multiple transfers.
  test "when 2 options exist, only auto-match one at a time, ranked by days apart" do
    yesterday_outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    yesterday_inflow = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -500)

    today_outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    today_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_difference -> { Transfer.count } => 2 do
      @family.auto_match_transfers!
    end
  end

  test "does not auto-match any transfers that have been rejected by user already" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    RejectedTransfer.create!(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "does not consider inactive accounts when matching transfers" do
    @depository.disable!

    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "does not match transactions outside the 4-day window" do
    create_transaction(date: 10.days.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "does not match multi-currency transfer with missing exchange rate" do
    # A known route, so the missing rate is the only thing in the way: never a rate of 1
    confirm_route!(from: @depository, to: @credit_card)
    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "GBP")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "a confirmed auto-match sets the outflow kind from the destination account" do
    loan = accounts(:loan)
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: loan, amount: -500)

    auto_match_and_confirm_transfers!

    assert_equal "loan_payment", outflow.transaction.reload.kind
    assert_equal "funds_movement", inflow.transaction.reload.kind
  end

  test "auto-match treats a withdrawal from an investment account as a plain transfer" do
    outflow = create_transaction(date: Date.current, account: accounts(:investment), amount: 500)
    inflow = create_transaction(date: Date.current, account: @depository, amount: -500)

    auto_match_and_confirm_transfers!

    assert_equal "funds_movement", outflow.transaction.reload.kind
  end

  test "does not auto-match excluded transactions" do
    create_transaction(date: Date.current, account: @depository, amount: 500, excluded: true)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "does not auto-match pending transactions" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    outflow.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "does not auto-match a transaction the user marked as one-time" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500, kind: "one_time")
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end

    assert_equal "one_time", outflow.transaction.reload.kind
  end

  test "a removed transfer is not matched again" do
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)

    @family.auto_match_transfers!
    inflow.transaction.reload.transfer.reject!

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "a pair that loses a race is skipped without aborting the rest of the run" do
    outflow1 = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow1 = create_transaction(date: Date.current, account: @credit_card, amount: -500)
    create_transaction(date: Date.current, account: @depository, amount: 700)
    inflow2 = create_transaction(date: Date.current, account: @credit_card, amount: -700)

    # Candidates were read before another run committed a transfer for the first pair
    candidates = @family.send(:auto_match_candidates).to_a
    Transfer.insert_all!([ { inflow_transaction_id: inflow1.entryable_id, outflow_transaction_id: outflow1.entryable_id, status: "pending" } ])
    @family.stubs(:auto_match_candidates).returns(candidates)
    # Skip the app-level uniqueness check so the insert hits the database index, as it would in a real race
    Transfer.any_instance.stubs(:valid?).returns(true)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(inflow_transaction_id: inflow2.entryable_id)
  end

  test "auto-match takes the family transfer lock" do
    @family.expects(:lock_transfer_matching!).once
    @family.auto_match_transfers!
  end

  # --- Match policy (w2-transfers transfer-match-policy, decision 20) ---

  test "an auto-match is a pending suggestion that leaves both legs as they were" do
    ensure_investment_contributions_category(@family)
    outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: accounts(:investment), amount: -500)

    @family.auto_match_transfers!

    transfer = Transfer.find_by!(inflow_transaction_id: inflow.entryable_id)
    assert transfer.pending?
    assert_equal "standard", outflow.transaction.reload.kind
    assert_equal "standard", inflow.transaction.reload.kind
    assert_nil outflow.transaction.category
  end

  test "does nothing while auto-matching is turned off" do
    @family.update!(auto_match_transfers_disabled: true)
    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -500)

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "the preferences switch reads as on and stores the opt-out" do
    assert @family.auto_match_transfers_enabled?

    @family.update!(auto_match_transfers_enabled: "0")
    assert @family.reload.auto_match_transfers_disabled?

    @family.update!(auto_match_transfers_enabled: "1")
    assert_not @family.reload.auto_match_transfers_disabled?
  end

  test "cross-currency pairs between manual accounts need a confirmed route" do
    load_exchange_prices
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "a route confirmed in the other direction does not count" do
    load_exchange_prices
    confirm_route!(from: @credit_card, to: @depository)
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "a pending transfer is not a route" do
    load_exchange_prices
    confirm_route!(from: @depository, to: @credit_card).update_column(:status, "pending")
    create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    assert_no_difference -> { Transfer.count } do
      @family.auto_match_transfers!
    end
  end

  test "the manual match dialog still offers a cross-currency pair with no route" do
    load_exchange_prices
    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 500)
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    candidates = outflow.transaction.transfer_match_candidates

    assert_includes candidates.map(&:inflow_transaction_id), inflow.entryable_id
  end

  test "a pair between two non-family currencies converts through the family currency" do
    confirm_route!(from: @depository, to: @credit_card)
    # Rates are stored into the family currency (USD) only: no direct GBP -> CAD rate
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: 1.day.ago.to_date, rate: 1.25)
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: 1.day.ago.to_date, rate: 0.74)

    outflow = create_transaction(date: 1.day.ago.to_date, account: @depository, amount: 400, currency: "GBP")
    # 400 x 1.25 / 0.74 = 675.68 CAD; 680 is within 5%
    inflow = create_transaction(date: Date.current, account: @credit_card, amount: -680, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end

    assert Transfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
  end

  test "the nearest stored rate converts a pair whose day has no rate" do
    confirm_route!(from: @depository, to: @credit_card)
    ExchangeRate.create!(from_currency: "USD", to_currency: "CAD", date: 10.days.ago.to_date, rate: 1.40)

    create_transaction(date: Date.current, account: @depository, amount: 500)
    create_transaction(date: Date.current, account: @credit_card, amount: -700, currency: "CAD")

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!
    end
  end

  test "an exact same-currency pair wins over a closer cross-currency guess" do
    load_exchange_prices
    confirm_route!(from: @depository, to: @credit_card)
    outflow = create_transaction(date: 2.days.ago.to_date, account: @depository, amount: 500)
    # The guess is on the outflow's day, the exact counterpart one day later
    create_transaction(date: 2.days.ago.to_date, account: @credit_card, amount: -690, currency: "CAD")
    exact = create_transaction(date: 1.day.ago.to_date, account: @credit_card, amount: -500)

    @family.auto_match_transfers!

    assert_equal exact.entryable_id, Transfer.find_by!(outflow_transaction_id: outflow.entryable_id).inflow_transaction_id
  end

  test "account-scoped matching only pairs transactions with a leg in that account" do
    depository_outflow = create_transaction(date: Date.current, account: @depository, amount: 500)
    credit_card_inflow = create_transaction(date: Date.current, account: @credit_card, amount: -500)
    other_outflow = create_transaction(date: Date.current, account: accounts(:other_asset), amount: 700)
    loan_inflow = create_transaction(date: Date.current, account: accounts(:loan), amount: -700)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!(account: @depository)
    end
    assert Transfer.exists?(inflow_transaction_id: credit_card_inflow.entryable_id, outflow_transaction_id: depository_outflow.entryable_id)

    assert_difference -> { Transfer.count } => 1 do
      @family.auto_match_transfers!(account: accounts(:loan))
    end
    assert Transfer.exists?(inflow_transaction_id: loan_inflow.entryable_id, outflow_transaction_id: other_outflow.entryable_id)
  end

  private
    # A transfer the user confirmed between the two accounts, in that direction
    def confirm_route!(from:, to:)
      outflow = create_transaction(date: 20.days.ago.to_date, account: from, amount: 100)
      inflow = create_transaction(date: 20.days.ago.to_date, account: to, amount: -100)
      Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "confirmed")
    end

    def auto_match_and_confirm_transfers!
      @family.auto_match_transfers!
      Transfer.pending.where.not(id: transfers(:one).id).find_each(&:confirm!)
    end

    def load_exchange_prices
      rates = {
        4.days.ago.to_date => 1.36,
        3.days.ago.to_date => 1.37,
        2.days.ago.to_date => 1.38,
        1.day.ago.to_date  => 1.39,
        Date.current => 1.40
      }

      rates.each do |date, rate|
        # USD to CAD
        ExchangeRate.create!(
          from_currency: "USD",
          to_currency: "CAD",
          date: date,
          rate: rate
        )

        # CAD to USD (inverse)
        ExchangeRate.create!(
          from_currency: "CAD",
          to_currency: "USD",
          date: date,
          rate: (1.0 / rate).round(6)
        )
      end
    end
end
