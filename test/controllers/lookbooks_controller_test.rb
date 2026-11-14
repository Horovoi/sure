require "test_helper"

# ViewComponent takes its preview controller from config.view_component.previews.controller.
# With the wrong setting the previews fall back to the gem's controller and the application
# layout, and every preview returns a 500.
class LookbooksControllerTest < ActionDispatch::IntegrationTest
  test "renders a component preview in the lookbooks layout" do
    get "/design-system/preview/alert/default"

    assert_response :success
    assert_select "title", "Component Preview"
    assert_select "body", text: /This is an alert message\./
  end

  test "every preview renders" do
    Lookbook.previews.flat_map(&:scenarios).each do |scenario|
      get "/design-system/preview/#{scenario.lookup_path}"

      assert_response :success, "#{scenario.lookup_path} did not render"
    end
  end
end
