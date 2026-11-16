require "test_helper"

class SplitsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @food = categories(:food_and_drink)
    @other = categories(:subscriptions)
    @entry = create_transaction(account: accounts(:depository), name: "Supermarket", amount: 100, category: @food)
  end

  test "new opens the editor with the whole amount on the first part" do
    get new_transaction_split_path(@entry)

    assert_response :success
    assert_select "form[action='#{transaction_split_path(@entry)}'][data-controller='split-editor']"
    assert_select "input[name='split[parts][0][amount]'][value='100.00']"
    assert_select "input[name='split[parts][1][amount]']"
    assert_select "template input[name='split[parts][__INDEX__][name]']"
  end

  test "new refuses a transaction that cannot be split" do
    get new_transaction_split_path(entries(:transfer_out))

    assert_redirected_to transactions_url
    assert_match "transfer", flash[:alert]
  end

  test "create splits with amounts in the transaction's own direction" do
    post transaction_split_path(@entry), params: { split: { parts: {
      "0" => { name: "Groceries", amount: "60", category_id: @food.id },
      "1" => { name: "Soap", amount: "40", category_id: @other.id, notes: "for the bathroom", excluded: "1", tag_ids: [ tags(:one).id ] }
    } } }

    assert_redirected_to transactions_url
    assert_equal "Transaction split", flash[:notice]

    @entry.reload
    assert @entry.split_parent?
    groceries, soap = @entry.child_entries
    assert_equal [ 60, 40 ], [ groceries.amount, soap.amount ]
    assert_equal @other, soap.transaction.category
    assert soap.excluded?
    assert_equal "for the bathroom", soap.notes
    assert_equal [ tags(:one) ], soap.transaction.tags.to_a
  end

  test "an income splits into income parts" do
    income = create_transaction(amount: -500, name: "Salary")

    post transaction_split_path(income), params: { split: { parts: {
      "0" => { name: "Pay", amount: "450" }, "1" => { name: "Refund", amount: "50" }
    } } }

    assert_equal [ -450, -50 ], income.reload.child_entries.map(&:amount)
  end

  test "create shows the editor again with the error when the parts do not add up" do
    post transaction_split_path(@entry), params: { split: { parts: {
      "0" => { name: "A", amount: "60" }, "1" => { name: "B", amount: "30" }
    } } }

    assert_response :unprocessable_entity
    assert_select "[role=alert]", /add up to/
    assert_select "input[name='split[parts][1][amount]'][value='30.00']"
    assert_not @entry.reload.split_parent?
  end

  test "another family's category is dropped" do
    foreign = Category.create!(family: families(:empty), name: "Foreign", color: "#123456")

    post transaction_split_path(@entry), params: { split: { parts: {
      "0" => { name: "A", amount: "60", category_id: foreign.id }, "1" => { name: "B", amount: "40" }
    } } }

    assert_nil @entry.reload.child_entries.first.transaction.category_id
  end

  test "edit, update and destroy work from a part too" do
    first, second = @entry.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])

    get edit_transaction_split_path(second)
    assert_response :success
    assert_select "input[name='split[parts][0][id]'][value='#{first.id}']"

    patch transaction_split_path(second), params: { split: { parts: {
      "0" => { id: first.id, name: "A", amount: "25" },
      "1" => { id: second.id, name: "B", amount: "25" },
      "2" => { name: "C", amount: "50", category_id: @food.id }
    } } }
    assert_redirected_to transactions_url
    assert_equal [ 25, 25, 50 ], @entry.reload.child_entries.map(&:amount)
    assert_equal first.id, @entry.child_entries.first.id

    delete transaction_split_path(first)
    assert_redirected_to transactions_url
    assert_not @entry.reload.split_parent?
    assert_not @entry.excluded?
  end

  test "saving goes back to the page the editor was opened over, never to the editor itself" do
    first, second = @entry.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    parts = { "0" => { id: first.id, name: "A", amount: "50" }, "1" => { id: second.id, name: "B", amount: "50" } }

    # Opened at its own URL, from a part
    patch transaction_split_path(second), params: { split: { parts: parts } }, headers: { "Referer" => edit_transaction_split_url(second) }
    assert_redirected_to transactions_path

    patch transaction_split_path(@entry), params: { split: { parts: parts } }, headers: { "Referer" => edit_transaction_split_url(@entry) }
    assert_redirected_to transactions_path

    # Opened from the list, in the drawer
    list = transactions_url(q: { search: "Supermarket" })
    patch transaction_split_path(@entry), params: { split: { parts: parts } }, headers: { "Referer" => list }
    assert_redirected_to list
  end

  test "the drawer of a split and of a part" do
    child = @entry.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ]).first

    get entry_path(@entry)
    assert_response :success
    assert_select "a[href='#{edit_transaction_split_path(@entry)}']"
    assert_select "a[href='#{entry_path(child)}']"
    assert_select "a[href='#{new_transaction_split_path(@entry)}']", count: 0

    get entry_path(child)
    assert_response :success
    assert_select "a[href='#{entry_path(@entry)}']"
    assert_select "input[name='entry[amount]'][disabled]"
  end

  test "the list groups the parts under the split, and the category filter finds a part" do
    @entry.split!([ { name: "Groceries part", amount: 60, category_id: @food.id }, { name: "Soap part", amount: 40, category_id: @other.id } ])

    get transactions_path
    assert_response :success
    assert_select "[data-testid=split-group]", 1 do
      assert_select "a[href='#{entry_path(@entry)}']", text: "Supermarket"
      assert_select "a", text: "Groceries part"
      assert_select "a", text: "Soap part"
    end

    get transactions_path(q: { categories: [ @other.name ] })
    assert_select "a", text: "Soap part"
    assert_select "a", text: "Groceries part", count: 0
  end

  test "a part cannot be deleted on its own" do
    child = @entry.split!([ { amount: 60 }, { amount: 40 } ]).first

    assert_no_difference "Entry.count" do
      delete entry_path(child)
    end
    assert_match "split", flash[:alert]
  end
end
