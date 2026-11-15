require "test_helper"

class DS::LinkTest < ViewComponent::TestCase
  # The dashboard's desktop Customize link is icon-only and marked
  # `hidden lg:inline-flex`. Icon-only sizes used to add `inline-flex`
  # themselves, which beats `hidden`, so phones showed it next to the
  # mobile one.
  test "an icon-only link marked hidden stays hidden below its breakpoint" do
    render_inline(DS::Link.new(href: "/", icon: "layout-grid", variant: "outline", class: "hidden lg:inline-flex"))

    classes = page.find("a")[:class].split
    assert_includes classes, "hidden"
    assert_includes classes, "lg:inline-flex"
    refute_includes classes, "inline-flex"
  end

  test "a text link marked hidden keeps its alignment and gap for when it shows" do
    render_inline(DS::Link.new(href: "/", icon: "plus", text: "New", class: "hidden md:inline-flex"))

    classes = page.find("a")[:class].split
    assert_includes classes, "items-center"
    assert_includes classes, "gap-1"
    refute_includes classes, "inline-flex"
  end

  test "an icon-only link without a display override is a centred inline-flex box" do
    render_inline(DS::Link.new(href: "/", icon: "plus", variant: "icon"))

    classes = page.find("a")[:class].split
    assert_includes classes, "inline-flex"
    assert_includes classes, "items-center"
    assert_includes classes, "justify-center"
  end

  test "the default variant is an underlined text link" do
    render_inline(DS::Link.new(href: "/", text: "Learn more", variant: :default))

    classes = page.find("a")[:class].split
    assert_includes classes, "text-link"
    assert_includes classes, "underline"
    assert_includes classes, "focus-ring"
  end

  test "a link that opens a new tab gets noopener and says so to screen readers" do
    render_inline(DS::Link.new(href: "https://example.com", text: "Docs", variant: :default, target: "_blank"))

    assert_selector "a[target='_blank'][rel='noopener noreferrer']"
    assert_selector "a .sr-only", text: I18n.t("ds.link.opens_in_new_tab")
  end

  test "method: becomes a Turbo method" do
    render_inline(DS::Link.new(href: "/sessions/1", text: "Log out", variant: :ghost, method: :delete))

    assert_selector "a[data-turbo-method='delete']"
    assert_no_selector "a[method]"
  end

  test "an icon on the right renders after the text" do
    render_inline(DS::Link.new(href: "/", text: "Next", icon: "arrow-right", icon_position: :right))

    assert_match(/Next.*<svg/m, page.find("a").native.inner_html)
  end

  test "an icon-only link gets an aria-label from its icon" do
    render_inline(DS::Link.new(href: "/", icon: "settings", variant: "icon"))

    assert_selector "a[aria-label='Settings']"
  end
end
