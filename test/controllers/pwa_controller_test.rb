require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  test "manifest is JSON with a padded maskable icon for an html accept header" do
    get "/manifest", headers: { "Accept" => "text/html" }

    assert_response :success
    assert_equal "application/manifest+json", response.media_type

    manifest = JSON.parse(response.body)
    assert_equal "/", manifest["start_url"]
    assert_equal "standalone", manifest["display"]
    assert_not manifest.key?("display_override")

    maskable = manifest["icons"].select { |icon| icon["purpose"] == "maskable" }
    assert_equal [ "/logo-pwa-maskable.png" ], maskable.map { |icon| icon["src"] }

    regular = manifest["icons"].reject { |icon| icon["purpose"] == "maskable" }
    assert_includes regular.map { |icon| icon["src"] }, "/logo-pwa.png"
    assert_not_includes regular.map { |icon| icon["src"] }, "/logo-pwa-maskable.png"
  end

  test "every manifest icon exists in public" do
    get "/manifest"

    JSON.parse(response.body)["icons"].each do |icon|
      assert Rails.public_path.join(icon["src"].delete_prefix("/")).file?, "missing #{icon["src"]}"
    end
  end

  test "manifest is served the same to a signed-in user" do
    sign_in users(:family_admin)

    get "/manifest", headers: { "Accept" => "text/html" }

    assert_response :success
    assert_equal "application/manifest+json", response.media_type
  end

  test "service worker is JavaScript without origin or referer headers, with forgery protection on" do
    with_forgery_protection do
      get "/service-worker", headers: { "Accept" => "*/*", "DNT" => "1", "Sec-GPC" => "1" }
    end

    assert_response :success
    assert_equal "application/javascript", response.media_type
    assert_includes response.body, "addEventListener('install'"
  end

  test "service worker is JavaScript for an html accept header" do
    get "/service-worker", headers: { "Accept" => "text/html" }

    assert_response :success
    assert_equal "application/javascript", response.media_type
  end

  test "pages link opaque padded apple touch icons" do
    sign_in users(:family_admin)

    get root_path

    assert_response :success
    assert_select "link[rel='manifest'][href^='/manifest']"
    hrefs = css_select("link[rel='apple-touch-icon']").map { |link| link["href"] }
    assert_includes hrefs, "/apple-touch-icon.png"
    hrefs.each do |href|
      assert Rails.public_path.join(href.delete_prefix("/")).file?, "missing #{href}"
    end
    assert_select "html[data-controller~='viewport']"
  end

  private
    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
end
