require "test_helper"

# Reports read a split transaction as its parts (Entry::Splittable): the export, the
# printed report and the report page show what the same parts as plain transactions show.
class ReportsSplitTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @food = categories(:food_and_drink)
    @subscriptions = categories(:subscriptions)
    @parts = [
      { name: "Food part", amount: 70, category_id: @food.id },
      { name: "Streaming part", amount: 25, category_id: @subscriptions.id },
      { name: "Excluded part", amount: 5, excluded: true }
    ]
  end

  test "the export, the print view and the breakdown match plain transactions" do
    entry = create_transaction(account: accounts(:depository), date: Date.current, amount: 100, name: "Supermarket", category: @food)
    entry.split!(@parts)
    with_split = report_outputs
    assert_includes with_split[:csv], "Subscriptions,$25.00", "a part counts in its own category"
    assert_includes with_split[:print_figures], "$25.00"

    entry.reload.unsplit!
    entry.reload.destroy!
    @parts.each do |part|
      create_transaction(account: accounts(:depository), date: Date.current, name: part[:name], amount: part[:amount],
        excluded: part[:excluded] || false, category: part[:category_id] && Category.find(part[:category_id]))
    end
    with_plain = report_outputs

    assert_equal with_plain[:csv], with_split[:csv]
    assert_equal with_plain[:print_figures], with_split[:print_figures]
    assert_equal with_plain[:index_figures], with_split[:index_figures]
  end

  private
    def report_outputs
      params = { period_type: :custom, start_date: Date.current.beginning_of_month, end_date: Date.current }

      get export_transactions_reports_path(format: :csv, **params)
      assert_response :ok
      csv = response.body

      get print_reports_path(**params)
      assert_response :ok
      print_figures = money_figures(response.body)

      get reports_path(**params)
      assert_response :ok
      index_figures = money_figures(response.body)

      { csv: csv, print_figures: print_figures, index_figures: index_figures }
    end

    # Every money amount on the page, in page order
    def money_figures(html)
      Nokogiri::HTML(html).text.scan(/-?\$[\d,]+\.\d{2}/)
    end
end
