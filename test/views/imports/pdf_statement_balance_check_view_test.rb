require "test_helper"

class Imports::PdfStatementBalanceCheckViewTest < ActionView::TestCase
  setup do
    @account = accounts(:depository)
    @import = families(:dylan_family).imports.create!(type: "PdfImport", account: @account, date_format: "%Y-%m-%d")
    @import.update_columns(status: "complete", ai_summary: "Summary", document_type: "bank_statement")
  end

  test "the Complete screen shows a matching balance" do
    stub_checks(check(:opening, :match, 1000, 1000), check(:closing, :match, 1150, 1150))

    html = render_complete

    assert_includes html, I18n.t("imports.pdf_statement_balance_check.title")
    assert_includes html, I18n.t("imports.pdf_statement_balance_check.sides.opening")
    assert_includes html, I18n.t("imports.pdf_statement_balance_check.sides.closing")
    assert_equal 2, html.scan(I18n.t("imports.pdf_statement_balance_check.match")).size
  end

  test "the Complete screen shows the difference of a mismatching balance" do
    stub_checks(check(:opening, :match, 1000, 1000), check(:closing, :mismatch, 1150, 1100))

    html = render_complete

    assert_includes html, I18n.t("imports.pdf_statement_balance_check.difference", amount: "$50.00")
    assert_includes html, I18n.t("imports.pdf_statement_balance_check.statement_amount", amount: "$1,150.00")
    assert_includes html, I18n.t("imports.pdf_statement_balance_check.account_amount", amount: "$1,100.00")
  end

  test "the Complete screen says not available when the data is missing or not synced" do
    stub_checks(check(:opening, :missing, nil, nil, date: nil), check(:closing, :not_synced, 1150, nil))

    html = render_complete

    assert_equal 2, html.scan(I18n.t("imports.pdf_statement_balance_check.not_available")).size
    assert_includes html, I18n.t("imports.pdf_statement_balance_check.missing")
    assert_includes html, I18n.t("imports.pdf_statement_balance_check.not_synced")
  end

  test "the check is not shown before the import is complete" do
    @import.update_columns(status: "pending")
    PdfImport.any_instance.expects(:statement_balance_check).never

    html = render(partial: "imports/pdf_import", locals: { import: PdfImport.find(@import.id) })

    assert_not_includes html, I18n.t("imports.pdf_statement_balance_check.title")
  end

  private
    def render_complete
      render(partial: "imports/pdf_import", locals: { import: @import })
    end

    def stub_checks(*checks)
      @import.stubs(:statement_balance_check).returns(checks)
    end

    def check(side, status, statement, account, date: Date.new(2024, 3, 31))
      PdfImport::BalanceCheck.new(
        side: side,
        date: date,
        status: status,
        statement_amount: statement && Money.new(statement, "USD"),
        account_amount: account && Money.new(account, "USD")
      )
    end
end
