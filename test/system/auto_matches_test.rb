require "application_system_test_case"

class AutoMatchesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family

    # Only this test's matches on the page
    Transfer.pending.find_each(&:destroy!)

    @first = create_pending_transfer("Card payment one", 300)
    @second = create_pending_transfer("Card payment two", 400)
    @left = create_pending_transfer("Card payment three", 500)
  end

  test "bulk confirm confirms the selected matches and leaves the rest" do
    visit auto_matches_url

    assert_selector "[data-testid=auto-match-row]", count: 3
    assert_no_selector "[data-testid=auto-match-bulk-bar]", visible: true

    find("#select_transfer_#{@first.id}").check
    find("#select_transfer_#{@second.id}").check

    within "[data-testid=auto-match-bulk-bar]" do
      assert_text "2 selected"
      click_on I18n.t("auto_matches.index.confirm_selected")
    end

    assert_text I18n.t("auto_matches.bulk_update.confirmed", count: 2)
    assert_selector "[data-testid=auto-match-row]", count: 1
    assert_text "Card payment three"

    assert @first.reload.confirmed?
    assert @second.reload.confirmed?
    assert @left.reload.pending?
    assert_equal "cc_payment", @first.outflow_transaction.reload.kind
  end

  test "select all then reject removes every match on the page" do
    visit auto_matches_url

    check "auto_match_select_all"

    within "[data-testid=auto-match-bulk-bar]" do
      assert_text "3 selected"
      click_on I18n.t("auto_matches.index.reject_selected")
    end

    assert_text I18n.t("auto_matches.index.empty_title")
    assert_equal 0, Transfer.where(id: [ @first.id, @second.id, @left.id ]).count
  end

  private
    def create_pending_transfer(name, amount)
      outflow = accounts(:depository).entries.create!(
        name: name, date: Date.current, amount: amount, currency: "USD", entryable: Transaction.new
      )
      inflow = accounts(:credit_card).entries.create!(
        name: "#{name} received", date: Date.current, amount: -amount, currency: "USD", entryable: Transaction.new
      )
      Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: outflow.entryable)
    end
end
