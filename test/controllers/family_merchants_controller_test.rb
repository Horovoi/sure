require "test_helper"

class FamilyMerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
  end

  test "index" do
    get family_merchants_path
    assert_response :success
  end

  test "new" do
    get new_family_merchant_path
    assert_response :success
  end

  test "should create merchant" do
    assert_difference("FamilyMerchant.count") do
      post family_merchants_url, params: { family_merchant: { name: "new merchant", color: "#000000" } }
    end

    assert_redirected_to family_merchants_path
  end

  test "should update merchant" do
    patch family_merchant_url(@merchant), params: { family_merchant: { name: "new name", color: "#000000" } }
    assert_redirected_to family_merchants_path
  end

  test "should destroy merchant" do
    assert_difference("FamilyMerchant.count", -1) do
      delete family_merchant_url(@merchant)
    end

    assert_redirected_to family_merchants_path
  end

  # --- DS pickers: inline create through the JSON endpoint ---

  test "JSON create returns the new merchant with its option markup" do
    assert_difference "FamilyMerchant.count", +1 do
      post family_merchants_url(format: :json), params: { family_merchant: { name: "Corner Bakery" } }, as: :json
    end

    assert_response :created
    body = response.parsed_body
    assert_equal "Corner Bakery", body["name"]
    assert_includes body["html"], %(data-merchant-id="#{body["id"]}")
  end

  test "JSON create returns the validation errors" do
    post family_merchants_url(format: :json), params: { family_merchant: { name: "" } }, as: :json

    assert_response :unprocessable_entity
    assert response.parsed_body["errors"].any?
  end

  # --- Merchant page ---

  test "show lists the merchant's transactions from every account and no others" do
    on_cash = merchant_transaction(name: "Netflix cash", account: accounts(:depository))
    on_card = merchant_transaction(name: "Netflix card", account: accounts(:credit_card))
    other = merchant_transaction(name: "Amazon order", merchant: merchants(:amazon))

    get family_merchant_url(@merchant)

    assert_response :success
    assert_select "h1", text: @merchant.name
    assert_select "turbo-frame##{dom_id(on_cash)}"
    assert_select "turbo-frame##{dom_id(on_card)}"
    assert_select "turbo-frame##{dom_id(other)}", count: 0
  end

  test "show totals are in the family currency at the nearest stored rate and leave out amounts with no rate" do
    merchant_transaction(amount: 10, currency: "USD")
    merchant_transaction(amount: 20, currency: "EUR", date: Date.current)
    merchant_transaction(amount: 500, currency: "JPY") # no JPY rate: left out, never counted at 1
    # The nearest rate is older than the entry; it is still used
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.5, date: 20.days.ago.to_date)

    get family_merchant_url(@merchant)

    assert_response :success
    assert_includes response.body, Money.new(40, "USD").format # 10 + 20 * 1.5
    assert_not_includes response.body, Money.new(540, "USD").format
    assert_not_includes response.body, Money.new(530, "USD").format
  end

  test "show leaves out spending when the type filter hides expenses" do
    merchant_transaction(amount: 10)

    get family_merchant_url(@merchant, q: { types: [ "income" ] })

    assert_response :success
    assert_no_match I18n.t("family_merchants.show.total_spending"), response.body
  end

  test "show keeps its merchant whatever q[merchants] says" do
    mine = merchant_transaction(name: "Netflix")
    amazon = merchant_transaction(name: "Amazon", merchant: merchants(:amazon))

    get family_merchant_url(@merchant, q: { merchants: [ merchants(:amazon).name ] })

    assert_select "turbo-frame##{dom_id(mine)}"
    assert_select "turbo-frame##{dom_id(amazon)}", count: 0
  end

  test "show pages the transactions" do
    12.times { |i| merchant_transaction(name: "Netflix #{i}", date: i.days.ago.to_date) }

    get family_merchant_url(@merchant, per_page: 10)
    assert_select "turbo-frame[id^='entry_']", count: 10

    get family_merchant_url(@merchant, per_page: 10, page: 2)
    assert_select "turbo-frame[id^='entry_']", count: 2
  end

  test "show refuses another family's merchant" do
    get family_merchant_url(merchants(:one))

    assert_response :not_found
  end

  test "show links Edit back to the same page" do
    get family_merchant_url(@merchant, q: { search: "net" })

    assert_select "a[href=?]", edit_family_merchant_path(@merchant, return_to: family_merchant_path(@merchant, q: { search: "net" }))
  end

  test "clear_filter removes one filter and keeps the others" do
    delete clear_filter_family_merchant_url(@merchant, param_key: "types", param_value: "expense",
                                            q: { types: %w[expense income], search: "net" })

    assert_redirected_to family_merchant_path(@merchant, q: { search: "net", types: [ "income" ] })
  end

  test "a transaction row links its merchant to the merchant page" do
    merchant_transaction(name: "Netflix")

    get transactions_url

    assert_select "a[href=?]", family_merchant_path(@merchant)
  end

  # --- Return to the merchant page after an edit ---

  test "edit keeps return_to in the form" do
    get edit_family_merchant_url(@merchant, return_to: family_merchant_path(@merchant))

    assert_select "input[type=hidden][name=return_to][value=?]", family_merchant_path(@merchant)
  end

  test "update returns to the given path" do
    patch family_merchant_url(@merchant), params: { return_to: family_merchant_path(@merchant), family_merchant: { name: "new name" } }

    assert_redirected_to family_merchant_path(@merchant)
  end

  test "update ignores a return_to that is not a path on this site" do
    [ "//evil.example", "/\t/evil.example", "https://evil.example" ].each do |return_to|
      patch family_merchant_url(@merchant), params: { return_to: return_to, family_merchant: { name: "new name" } }

      assert_redirected_to family_merchants_path
    end
  end

  # --- Logo upload ---

  test "update uploads a logo, which then comes before the website logo" do
    @merchant.update_columns(logo_url: "https://cdn.brandfetch.io/netflix.com/icon/fallback/lettermark/w/40/h/40?c=abc")

    patch family_merchant_url(@merchant), params: {
      family_merchant: { logo: file_fixture_upload("profile_image.png", "image/png", :binary) }
    }

    assert_redirected_to family_merchants_path
    @merchant.reload
    assert @merchant.logo.attached?
    assert_match %r{\A/rails/active_storage/representations/}, @merchant.logo_url
  end

  test "update refuses a logo that is not an image" do
    patch family_merchant_url(@merchant), params: {
      family_merchant: { logo: Rack::Test::UploadedFile.new(StringIO.new("not an image"), "text/plain", original_filename: "logo.txt") }
    }

    assert_response :unprocessable_entity
    assert_not @merchant.reload.logo.attached?
  end

  test "update with remove_logo detaches the uploaded logo" do
    @merchant.logo.attach(io: file_fixture("profile_image.png").open, filename: "logo.png", content_type: "image/png")

    patch family_merchant_url(@merchant), params: { family_merchant: { remove_logo: "1" } }

    assert_redirected_to family_merchants_path
    assert_not @merchant.reload.logo.attached?
    assert_nil @merchant.logo_url
  end

  test "the edit form offers the logo field and, with a logo, the remove toggle" do
    get edit_family_merchant_url(@merchant)
    assert_select "input[type=file][name='family_merchant[logo]']"
    assert_select "input[name='family_merchant[remove_logo]']", count: 0

    @merchant.logo.attach(io: file_fixture("profile_image.png").open, filename: "logo.png", content_type: "image/png")
    get edit_family_merchant_url(@merchant)
    assert_select "input[name='family_merchant[remove_logo]']"
  end

  # --- Merchants list: search, pagination, sub menu ---

  test "index searches family merchants and pages them" do
    get family_merchants_url(family_search: "netf")

    assert_response :success
    assert_select "a[href=?]", family_merchant_path(merchants(:netflix))
    assert_select "a[href=?]", family_merchant_path(merchants(:amazon)), count: 0
  end

  test "index pages family merchants" do
    12.times { |i| @user.family.merchants.create!(name: "Shop #{i.to_s.rjust(2, "0")}") }

    get family_merchants_url(per_page: 10)

    assert_response :success
    assert_select "nav a[href*='family_page=2']"
  end

  test "index puts Merge in the sub menu" do
    get family_merchants_url

    assert_select "[data-controller~='DS--menu'] a[href=?]", merge_family_merchants_path
  end

  test "the merge dialog has a searchable target and source list" do
    get merge_family_merchants_url

    assert_response :success
    assert_select "[data-controller~='list-filter'] input[type=search]"
    assert_select ".filterable-item input[name='source_ids[]'][value=?]", merchants(:amazon).id
  end

  test "merge keeps the source's recurring rows on the target" do
    recurring = recurring_transactions(:netflix_subscription)

    post perform_merge_family_merchants_url, params: { target_id: merchants(:amazon).id, source_ids: [ @merchant.id ] }

    assert_redirected_to family_merchants_path
    assert RecurringTransaction.exists?(recurring.id), "the recurring row survives the merge"
    assert_equal merchants(:amazon), recurring.reload.merchant
  end

  private
    def merchant_transaction(name: "Netflix", amount: 15, currency: "USD", date: Date.current, account: accounts(:depository), merchant: @merchant)
      account.entries.create!(name: name, amount: amount, currency: currency, date: date,
                              entryable: Transaction.new(merchant: merchant))
    end
end
