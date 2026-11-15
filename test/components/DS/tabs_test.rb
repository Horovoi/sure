require "test_helper"

class DS::TabsTest < ViewComponent::TestCase
  test "renders the WAI-ARIA tab pattern" do
    render_tabs

    assert_selector "div[role='tablist'][aria-orientation='horizontal']"
    assert_no_selector "nav"
    assert_selector "button[role='tab']", count: 2
    assert_selector "div[role='tabpanel']", count: 2, visible: :all
  end

  test "only the active tab is selected and in the tab order" do
    render_tabs

    assert_selector "button[role='tab'][aria-selected='true'][tabindex='0']", text: "All"
    assert_selector "button[role='tab'][aria-selected='false'][tabindex='-1']", text: "Assets"
  end

  test "each tab controls its panel and the panel is labelled by its tab" do
    render_tabs

    tab = page.find("button[role='tab']", text: "Assets")
    panel = page.find("##{tab[:'aria-controls']}", visible: :all)
    assert_equal "tabpanel", panel[:role]
    assert_equal tab[:id], panel[:'aria-labelledby']
    assert_equal "asset", tab[:'data-id']
  end

  # Two tab widgets on one page often reuse ids like "all"; the DOM ids are
  # scoped to the instance so the aria references cannot cross.
  test "two widgets with the same tab ids get distinct DOM ids" do
    render_inline(DS::Tabs.new(active_tab: "all")) do |tabs|
      tabs.with_nav { |nav| nav.with_btn(id: "all", label: "All") }
      tabs.with_panel(tab_id: "all") { "One" }
    end
    first_id = page.find("button[role='tab']")[:id]

    render_inline(DS::Tabs.new(active_tab: "all")) do |tabs|
      tabs.with_nav { |nav| nav.with_btn(id: "all", label: "All") }
      tabs.with_panel(tab_id: "all") { "Two" }
    end
    second_id = page.find("button[role='tab']")[:id]

    refute_equal first_id, second_id
  end

  test "tab buttons wire click and keyboard actions" do
    render_tabs

    assert_selector "button[role='tab'][data-action='click->DS--tabs#show keydown->DS--tabs#handleKeydown']", count: 2
  end

  private
    def render_tabs
      render_inline(DS::Tabs.new(active_tab: "all")) do |tabs|
        tabs.with_nav do |nav|
          nav.with_btn(id: "all", label: "All")
          nav.with_btn(id: "asset", label: "Assets")
        end
        tabs.with_panel(tab_id: "all") { "All accounts" }
        tabs.with_panel(tab_id: "asset") { "Asset accounts" }
      end
    end
end
