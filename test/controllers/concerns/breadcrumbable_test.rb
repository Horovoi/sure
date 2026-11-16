require "test_helper"

class BreadcrumbableTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "the default breadcrumb names the page, not the controller" do
    get settings_budgeting_path

    assert_response :success
    assert_equal [ I18n.t("breadcrumbs.home"), I18n.t("breadcrumbs.budgetings") ],
                 controller.instance_variable_get(:@breadcrumbs).map(&:first)
    assert_equal "Budgeting", I18n.t("breadcrumbs.budgetings")
  end

  test "a controller without its own name keeps the titleized one" do
    get tags_path

    assert_equal "Tags", controller.instance_variable_get(:@breadcrumbs).last.first
  end
end
