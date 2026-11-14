require "test_helper"

class StyledFormBuilderTest < ActionView::TestCase
  setup do
    @form = StyledFormBuilder.new(:entry, Entry.new, self, {})
  end

  test "text fields get the styled container and label" do
    html = @form.text_field(:name, label: "Name")

    assert_dom_equal_selector html, ".form-field label", "Name"
    assert_dom_equal_selector html, ".form-field input.form-field__input[name='entry[name]']"
  end

  # Rails 8 renamed text_area to textarea; both spellings must stay styled
  test "text_area and textarea are styled alike" do
    %i[text_area textarea].each do |helper|
      html = @form.public_send(helper, :notes, label: "Notes")

      assert_dom_equal_selector html, ".form-field label", "Notes"
      assert_dom_equal_selector html, ".form-field textarea.form-field__input[name='entry[notes]']"
      assert_no_match(/label="Notes"/, html, "#{helper} leaked the label option as an HTML attribute")
    end
  end

  # ...and check_box to checkbox; neither is a text field, so neither is wrapped
  test "check_box and checkbox are not wrapped as text fields" do
    %i[check_box checkbox].each do |helper|
      html = @form.public_send(helper, :excluded)

      assert_no_match(/form-field/, html)
      assert_match(/type="checkbox"/, html)
    end
  end

  private
    def assert_dom_equal_selector(html, selector, text = nil)
      nodes = Nokogiri::HTML5.fragment(html).css(selector)

      assert nodes.any?, "expected #{selector} in #{html}"
      assert_equal text, nodes.first.text if text
    end
end
