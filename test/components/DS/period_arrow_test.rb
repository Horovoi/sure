require "test_helper"

class DS::PeriodArrowTest < ViewComponent::TestCase
  test "with an href it is an icon link with its label and hotkey" do
    render_inline(DS::PeriodArrow.new(direction: :previous, label: "Previous period", href: "/reports?period_offset=-1", hotkey: "ArrowLeft"))

    link = page.find("a[href='/reports?period_offset=-1']")
    assert_equal "Previous period", link["aria-label"]
    assert_equal "ArrowLeft", link["aria-keyshortcuts"]
    assert_equal "hotkey", link["data-controller"]
    assert_equal "previous", link["data-period-arrow"]
  end

  test "a shortcut hint wraps the active arrow in a tooltip" do
    render_inline(DS::PeriodArrow.new(direction: :next, label: "Next period", href: "/next", shortcut_hint: "Next period (→)"))

    assert_selector "[data-controller='DS--tooltip'] a[aria-label='Next period']"
    assert_selector "[role='tooltip']", text: "Next period (→)", visible: :all
  end

  # The reports page used to render a disabled <button> that looked exactly
  # like the active arrow, then refused the click.
  test "without an href it is a greyed, non-interactive placeholder" do
    render_inline(DS::PeriodArrow.new(direction: :next, label: "Next period", hotkey: "ArrowRight", shortcut_hint: "Next period (→)"))

    assert_no_selector "a"
    assert_no_selector "button"
    assert_no_selector "[data-controller]"
    assert_no_selector "[role='tooltip']", visible: :all

    arrow = page.find("span[role='link'][aria-disabled='true']")
    assert_equal "Next period", arrow["aria-label"]
    classes = arrow[:class].split
    assert_includes classes, "text-subdued"
    assert_includes classes, "cursor-default"
    assert classes.none? { |c| c.start_with?("hover:") }, "a disabled arrow has no hover state"
  end

  test "the placeholder keeps the size of the active arrow so the row does not move" do
    render_inline(DS::PeriodArrow.new(direction: :next, label: "Next", href: "/next"))
    active = page.find("a")[:class].split

    render_inline(DS::PeriodArrow.new(direction: :next, label: "Next"))
    disabled = page.find("span[aria-disabled]")[:class].split

    %w[w-9 h-9 pointer-coarse:w-11 pointer-coarse:h-11].each do |size_class|
      assert_includes active, size_class
      assert_includes disabled, size_class
    end
  end

  test "an unknown direction raises" do
    assert_raises(ArgumentError) { DS::PeriodArrow.new(direction: :up, label: "Up") }
  end
end
