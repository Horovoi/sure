require "test_helper"

class DS::ToggleTest < ViewComponent::TestCase
  test "the checkbox announces itself as a switch" do
    render_inline(DS::Toggle.new(id: "notify", name: "user[notify]", checked: true))

    assert_selector "input[type='checkbox'][role='switch'][name='user[notify]']:checked", visible: :all
  end

  test "carries the off value in a paired hidden field" do
    render_inline(DS::Toggle.new(id: "notify", name: "user[notify]"))

    assert_selector "input[type='hidden'][name='user[notify]'][value='0']", visible: :all
    assert_selector "label[for='notify']"
  end

  test "shows the focus ring from the hidden input" do
    render_inline(DS::Toggle.new(id: "notify", name: "user[notify]"))

    assert_includes page.find("label")[:class].split, "peer-focus-visible:outline-focus-ring"
  end
end
