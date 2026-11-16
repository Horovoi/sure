require "application_system_test_case"
require "ostruct"

class ImportsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)

    # Trade securities will be imported as "offline" tickers
    Security.stubs(:provider).returns(nil)
  end

  test "transaction import" do
    visit new_import_path

    click_on "Import transactions"

    within_testid("import-tabs") do
      click_on "Copy & Paste"
    end

    fill_in "import[raw_file_str]", with: file_fixture("imports/transactions.csv").read

    within "form" do
      click_on "Upload CSV"
    end

    select "Date", from: "import[date_col_label]"
    select "YYYY-MM-DD", from: "import[date_format]"
    select "Amount", from: "import[amount_col_label]"
    select "Account", from: "import[account_col_label]"
    select "Name", from: "import[name_col_label]"
    select "Category", from: "import[category_col_label]"
    select "Tags", from: "import[tags_col_label]"
    select "Notes", from: "import[notes_col_label]"

    click_on "Apply configuration"

    click_on "Next step"

    assert_selector "h1", text: "Assign your categories"
    click_on "Next"

    assert_selector "h1", text: "Assign your tags"
    click_on "Next"

    assert_selector "h1", text: "Assign your accounts"
    click_on "Next"

    click_on "Publish import"

    assert_text "Import in progress"

    perform_enqueued_jobs

    click_on "Check status"

    assert_text "Import successful"

    click_on "Back to dashboard"
  end

  test "trade import" do
    visit new_import_path

    click_on "Import investments"

    within_testid("import-tabs") do
      click_on "Copy & Paste"
    end

    fill_in "import[raw_file_str]", with: file_fixture("imports/trades.csv").read

    within "form" do
      click_on "Upload CSV"
    end

    select "date", from: "import[date_col_label]"
    select "YYYY-MM-DD", from: "import[date_format]"
    select "qty", from: "import[qty_col_label]"
    select "ticker", from: "import[ticker_col_label]"
    select "price", from: "import[price_col_label]"
    select "account", from: "import[account_col_label]"

    click_on "Apply configuration"

    click_on "Next step"

    assert_selector "h1", text: "Assign your accounts"
    click_on "Next"

    click_on "Publish import"

    assert_text "Import in progress"

    perform_enqueued_jobs

    click_on "Check status"

    assert_text "Import successful"

    click_on "Back to dashboard"
  end

  test "account import" do
    visit new_import_path

    click_on "Import accounts"

    within_testid("import-tabs") do
      click_on "Copy & Paste"
    end

    fill_in "import[raw_file_str]", with: file_fixture("imports/accounts.csv").read

    within "form" do
      click_on "Upload CSV"
    end

    select "type", from: "import[entity_type_col_label]"
    select "name", from: "import[name_col_label]"
    select "amount", from: "import[amount_col_label]"

    click_on "Apply configuration"

    click_on "Next step"

    assert_selector "h1", text: "Assign your account types"

    all("form").each do |form|
      within(form) do
        select = form.find("select")
        select "Depository", from: select["id"]
        sleep 0.5
      end
    end

    click_on "Next"

    click_on "Publish import"

    assert_text "Import in progress"

    perform_enqueued_jobs

    click_on "Check status"

    assert_text "Import successful"

    click_on "Back to dashboard"
  end

  test "mint import" do
    visit new_import_path

    click_on "Import from Mint"

    within_testid("import-tabs") do
      click_on "Copy & Paste"
    end

    fill_in "import[raw_file_str]", with: file_fixture("imports/mint.csv").read

    within "form" do
      click_on "Upload CSV"
    end

    click_on "Apply configuration"

    click_on "Next step"

    assert_selector "h1", text: "Assign your categories"
    click_on "Next"

    assert_selector "h1", text: "Assign your tags"
    click_on "Next"

    assert_selector "h1", text: "Assign your accounts"
    click_on "Next"

    click_on "Publish import"

    assert_text "Import in progress"

    perform_enqueued_jobs

    click_on "Check status"

    assert_text "Import successful"

    click_on "Back to dashboard"
  end

  test "PDF import skips a transaction that is already recorded" do
    account = accounts(:depository)
    account.entries.create!(date: Date.new(2024, 3, 11), amount: 50, currency: "USD", name: "Coffee typed by hand", entryable: Transaction.new)

    provider = stub("openai")
    provider.stubs(:supports_pdf_processing?).returns(true)
    provider.stubs(:process_pdf).returns(OpenStruct.new(success?: true, data: OpenStruct.new(summary: "March statement", document_type: "bank_statement")))
    provider.stubs(:extract_bank_statement).returns(OpenStruct.new(
      success?: true,
      data: { transactions: [
        { date: "2024-03-10", amount: "-50", name: "CARD COFFEE" },
        { date: "2024-03-12", amount: "-25", name: "BAKERY" }
      ] }
    ))
    Provider::Registry.stubs(:get_provider).with(:openai).returns(provider)

    import = @user.family.imports.create!(type: "PdfImport", date_format: "%m/%d/%Y")
    import.pdf_file.attach(io: StringIO.new("%PDF-1.4 test"), filename: "statement.pdf", content_type: "application/pdf")
    import.process_with_ai_later
    perform_enqueued_jobs

    visit import_path(import)

    assert_text "Ready for review"
    select account.name, from: "pdf_import[account_id]"
    click_on "Save account"

    assert_text "1 transaction already recorded"
    find("summary", text: "1 transaction already recorded").click
    assert_link "Coffee typed by hand"

    click_on "Publish 1 new transaction"
    # Wait for the publish request, so the job is enqueued before it is performed
    assert_text "Import in progress"
    perform_enqueued_jobs
    visit import_path(import)

    assert_text "Import complete"
    assert_equal [ "BAKERY" ], import.reload.entries.pluck(:name)
    assert_equal 1, account.entries.where(name: "Coffee typed by hand").count
  end
end
