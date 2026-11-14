require "test_helper"

class ValuationsControllerTest < ActionDispatch::IntegrationTest
  include EntryableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:valuation)
  end

  test "can create reconciliation" do
    account = accounts(:investment)

    assert_difference [ "Entry.count", "Valuation.count" ], 1 do
      post valuations_url, params: {
        entry: {
          amount: account.balance + 100,
          date: Date.current.to_s,
          account_id: account.id
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first
    assert_equal "Manual value update", created_entry.name
    assert_equal Date.current, created_entry.date
    assert_equal account.balance + 100, created_entry.amount_money.to_f

    assert_enqueued_with job: SyncJob

    assert_redirected_to account_url(created_entry.account)
  end

  test "deleting an opening balance is refused" do
    account = accounts(:depository)
    anchor = account.entries.create!(date: 3.years.ago.to_date, name: "Opening", amount: 100, currency: "USD", entryable: Valuation.new(kind: "opening_anchor"))

    assert_no_difference "Entry.count" do
      delete valuation_url(anchor)
    end

    assert_redirected_to account_url(account)
    assert_equal I18n.t("activerecord.errors.models.entry.attributes.base.anchor_not_deletable"), flash[:alert]
  end

  test "a new balance on the opening balance date is refused before confirming" do
    account = accounts(:depository)
    account.entries.create!(date: 3.years.ago.to_date, name: "Opening", amount: 100, currency: "USD", entryable: Valuation.new(kind: "opening_anchor"))

    post confirm_create_valuations_url, params: { entry: { amount: 500, date: 3.years.ago.to_date, account_id: account.id } }

    assert_response :unprocessable_entity
  end

  test "updates entry with basic attributes" do
    assert_no_difference [ "Entry.count", "Valuation.count" ] do
      patch valuation_url(@entry), params: {
        entry: {
          amount: 22000,
          date: Date.current,
          notes: "Test notes"
        }
      }
    end

    assert_enqueued_with job: SyncJob

    assert_redirected_to account_url(@entry.account)

    @entry.reload
    assert_equal 22000, @entry.amount
    assert_equal "Test notes", @entry.notes
  end
end
