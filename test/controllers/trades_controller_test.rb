require "test_helper"

class TradesControllerTest < ActionDispatch::IntegrationTest
  include EntryableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:trade)
  end

  test "updates trade entry" do
    assert_no_difference [ "Entry.count", "Trade.count" ] do
      patch trade_url(@entry), params: {
        entry: {
          currency: "USD",
          entryable_attributes: {
            id: @entry.entryable_id,
            qty: 20,
            price: 20
          }
        }
      }
    end

    @entry.reload

    assert_enqueued_with job: SyncJob

    assert_equal 20, @entry.trade.qty
    assert_equal 20, @entry.trade.price
    assert_equal "USD", @entry.currency

    assert_redirected_to account_url(@entry.account)
  end

  test "creates deposit entry" do
    from_account = accounts(:depository) # Account the deposit is coming from

    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2,
                      -> { Transfer.count } => 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "deposit",
          date: Date.current,
          amount: 10,
          currency: "USD",
          transfer_account_id: from_account.id
        }
      }
    end

    assert_redirected_to @entry.account
  end

  test "creates withdrawal entry" do
    to_account = accounts(:depository) # Account the withdrawal is going to

    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2,
                      -> { Transfer.count } => 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "withdrawal",
          date: Date.current,
          amount: 10,
          currency: "USD",
          transfer_account_id: to_account.id
        }
      }
    end

    assert_redirected_to @entry.account
  end

  test "deposit and withdrawal has optional transfer account" do
    assert_difference -> { Entry.count } => 1,
                      -> { Transaction.count } => 1,
                      -> { Transfer.count } => 0 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "withdrawal",
          date: Date.current,
          amount: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.positive?
    assert_redirected_to @entry.account
  end

  test "creates interest entry" do
    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "interest",
          date: Date.current,
          amount: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert_redirected_to @entry.account
  end

  test "creates trade buy entry" do
    assert_difference [ "Entry.count", "Trade.count", "Security.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          ticker: "NVDA (NASDAQ)",
          qty: 10,
          price: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.positive?
    assert created_entry.trade.qty.positive?
    assert_equal "Entry created", flash[:notice]
    assert_enqueued_with job: SyncJob
    assert_redirected_to account_url(created_entry.account)
  end

  test "creates trade sell entry" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "sell",
          ticker: "AAPL (NYSE)",
          date: Date.current,
          currency: "USD",
          qty: 10,
          price: 10
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade.qty.negative?
    assert_equal "Entry created", flash[:notice]
    assert_enqueued_with job: SyncJob
    assert_redirected_to account_url(created_entry.account)
  end

  # The type select shows its fields in the browser, so every type's fields are on
  # the page; the other types' are in a disabled fieldset, which is not sent
  test "new trade form enables only the fields of a buy" do
    get new_trade_url(account_id: @entry.account_id)

    assert_response :ok
    assert_select "select[name='model[type]'] option[selected][value='buy']"
    assert_select "fieldset[data-types='buy sell']:not([disabled]):not([hidden])", count: 2
    assert_select "fieldset[data-types='deposit withdrawal interest'][disabled][hidden]"
    assert_select "fieldset[data-types='deposit withdrawal'][disabled][hidden]"
  end

  test "a failed sell shows the form again as a sell" do
    assert_no_difference "Entry.count" do
      post trades_url(account_id: @entry.account_id), params: {
        model: { type: "sell", manual_ticker: "AAPL", date: "", currency: "USD", qty: 10, price: 10 }
      }
    end

    assert_response :unprocessable_entity
    assert_select "select[name='model[type]'] option[selected][value='sell']"
    assert_select "fieldset[data-types='buy sell']:not([disabled])", count: 2
  end

  test "show labels a buy trade Buy" do
    assert @entry.amount.positive?
    assert @entry.trade.qty.positive?

    get trade_url(@entry)

    assert_response :ok
    assert_select "##{ActionView::RecordIdentifier.dom_id(@entry, :header)} span", text: I18n.t("trades.header.buy")
    assert_select "select[name='entry[nature]'] option[selected][value='outflow']"
  end

  test "show labels a sell trade Sell" do
    @entry.update_columns(amount: -@entry.amount)
    @entry.trade.update_columns(qty: -@entry.trade.qty)

    get trade_url(@entry)

    assert_response :ok
    assert_select "##{ActionView::RecordIdentifier.dom_id(@entry, :header)} span", text: I18n.t("trades.header.sell")
    assert_select "select[name='entry[nature]'] option[selected][value='inflow']"
  end

  test "a failed update sent as Turbo Stream renders the form, not a missing template" do
    patch trade_url(@entry),
      params: { entry: { date: "" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_entity
    assert_equal "text/html", response.media_type
    # The header keeps the stored date while the form holds the blank one
    assert_select "##{ActionView::RecordIdentifier.dom_id(@entry, :header)} span", text: I18n.l(@entry.reload.date, format: :long)
  end
end
