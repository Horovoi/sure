require "test_helper"

class Account::ProviderLinkTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    travel_to Date.new(2026, 11, 15)
    enable_bank_connections(:lunchflow)
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Mono Visa", balance: 0, currency: "USD", accountable: CreditCard.new)
    @item = LunchflowItem.create!(family: @family, name: "Bank", api_key: "key")
    @provider_account = @item.lunchflow_accounts.create!(name: "Card", currency: "USD", account_id: "card-1")
  end

  test "default cutover is the day after the latest transaction" do
    entry(5.days.ago)
    entry(2.days.ago)

    assert_equal 1.day.ago.to_date, Account::ProviderLink.default_cutover_date(@account)
  end

  test "an explicit cutover on or before the opening balance is refused" do
    Account::OpeningBalanceManager.new(@account).set_opening_balance(balance: 1_000, date: Date.new(2026, 10, 31))

    [ Date.new(2026, 10, 31), Date.new(2026, 10, 20) ].each do |date|
      assert_raises(Account::ProviderLink::InvalidCutover) do
        Account::ProviderLink.link!(account: @account, provider_account: @provider_account, cutover_date: date)
      end
    end

    Account::ProviderLink.link!(account: @account, provider_account: @provider_account, cutover_date: Date.new(2026, 11, 1))
    assert_equal Date.new(2026, 11, 1), @account.reload.provider_cutover_date
  end

  test "default cutover is capped at today and ignores future and valuation entries" do
    entry(Date.current)
    entry(3.days.from_now)
    @account.entries.create!(date: 1.day.from_now, amount: 10, currency: "USD", name: "Value", entryable: Valuation.new(kind: "reconciliation"))

    assert_equal Date.current, Account::ProviderLink.default_cutover_date(@account)
  end

  test "default cutover is nil for an account without transactions" do
    assert_nil Account::ProviderLink.default_cutover_date(@account)
  end

  test "link! stores the cutover and does not sync" do
    entry(4.days.ago)

    assert_no_enqueued_jobs only: SyncJob do
      link = Account::ProviderLink.link!(account: @account, provider_account: @provider_account)

      assert_equal 3.days.ago.to_date, link.cutover_date
    end

    assert @account.reload.linked?
    assert_equal 3.days.ago.to_date, @account.provider_cutover_date
  end

  test "link! takes an explicit cutover or none" do
    link = Account::ProviderLink.link!(account: @account, provider_account: @provider_account, cutover_date: "2026-11-10")
    assert_equal Date.new(2026, 11, 10), link.cutover_date

    Account::ProviderLink.unlink!(@account)
    link = Account::ProviderLink.link!(account: @account.reload, provider_account: @provider_account, cutover_date: nil)
    assert_nil link.cutover_date
  end

  test "link! refuses a future cutover or a second link" do
    assert_raises(Account::ProviderLink::InvalidCutover) do
      Account::ProviderLink.link!(account: @account, provider_account: @provider_account, cutover_date: 1.day.from_now.to_date)
    end
    assert_raises(Account::ProviderLink::InvalidCutover) do
      Account::ProviderLink.link!(account: @account, provider_account: @provider_account, cutover_date: "soon")
    end

    Account::ProviderLink.link!(account: @account, provider_account: @provider_account)
    other_account = @family.accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    other_provider_account = @item.lunchflow_accounts.create!(name: "Other", currency: "USD", account_id: "card-2")

    assert_raises(Account::ProviderLink::AlreadyLinked) do
      Account::ProviderLink.link!(account: @account, provider_account: other_provider_account)
    end
    assert_raises(Account::ProviderLink::AlreadyLinked) do
      Account::ProviderLink.link!(account: other_account, provider_account: @provider_account)
    end
  end

  test "balance strategy follows the link and the provider balance" do
    @account.entries.create!(date: 30.days.ago, amount: 100, currency: "USD", name: "Opening", entryable: Valuation.new(kind: "opening_anchor"))
    entry(4.days.ago)
    assert_equal :forward, @account.balance_strategy

    Account::ProviderLink.link!(account: @account, provider_account: @provider_account)
    @account.reload
    # Nothing changes until the provider writes its first balance
    assert_equal :forward, @account.balance_strategy

    Account::ProviderImportAdapter.new(@account).update_balance(balance: 120)
    assert_equal :cutover, @account.reload.balance_strategy
  end

  test "an account linked from the start runs in reverse" do
    Account::ProviderLink.link!(account: @account, provider_account: @provider_account)

    assert_nil @account.reload.provider_cutover_date
    assert_equal :reverse, @account.balance_strategy
  end

  test "unlink! makes the account manual, keeps holdings and converts anchors" do
    Account::ProviderLink.link!(account: @account, provider_account: @provider_account, cutover_date: nil)
    Account::ProviderImportAdapter.new(@account.reload).update_balance(balance: 120)
    link = @account.account_providers.first
    holding = Holding.create!(account: @account, security: securities(:aapl), date: Date.current, qty: 1, price: 1, amount: 1, currency: "USD", account_provider_id: link.id)

    assert_enqueued_with(job: SyncJob) do
      assert Account::ProviderLink.unlink!(@account)
    end

    @account.reload
    assert @account.manual?
    assert_nil holding.reload.account_provider_id
    assert_equal 0, @account.valuations.current_anchor.count
    assert_equal [ 120 ], @account.valuations.reconciliation.map { |valuation| valuation.entry.amount }
    assert LunchflowAccount.exists?(@provider_account.id)
  end

  test "provider_balance_includes_pending? reads the registered provider" do
    Account::ProviderLink.link!(account: @account, provider_account: @provider_account)
    assert_not @account.reload.provider_balance_includes_pending?

    BankConnections.stubs(:provider_for_account_class).with("LunchflowAccount").returns(stub(balance_includes_pending?: true))
    assert @account.provider_balance_includes_pending?
  end

  private
    def entry(date)
      @account.entries.create!(date: date.to_date, amount: 10, currency: "USD", name: "Manual", entryable: Transaction.new)
    end
end
