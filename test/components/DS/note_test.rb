require "test_helper"

class DS::NoteTest < ViewComponent::TestCase
  test "renders an inset panel with the title above the content" do
    render_inline(DS::Note.new(title: "Retention")) { "<p>Kept for 30 days.</p>".html_safe }

    assert_selector "div.rounded-md.border.border-secondary.bg-container-inset.text-xs.text-secondary"
    assert_selector "div > p.font-medium.text-primary:first-child", text: "Retention"
    assert_selector "div > p", text: "Kept for 30 days."
  end

  test "omits the title paragraph without a title" do
    render_inline(DS::Note.new) { "Body only" }

    assert_no_selector "p.font-medium"
    assert_text "Body only"
  end

  test "merges an extra class and forwards other options" do
    render_inline(DS::Note.new(class: "mt-4", id: "privacy-note")) { "Body" }

    assert_selector "div#privacy-note.mt-4.bg-container-inset"
  end
end
