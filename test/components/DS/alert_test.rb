require "test_helper"

class DS::AlertTest < ViewComponent::TestCase
  test "renders a message with the variant named for screen readers" do
    render_inline(DS::Alert.new(message: "Saved", variant: :success))

    assert_selector "p", text: "Saved"
    assert_selector ".sr-only", text: "#{I18n.t("ds.alert.variants.success")}:"
    assert_no_selector "[role]"
  end

  test "a live alert announces itself and is labelled by its title" do
    render_inline(DS::Alert.new(title: "Could not save", message: "Try again", variant: :error, live: :alert))

    alert = page.find("[role='alert']")
    title = page.find("##{alert[:'aria-labelledby']}")
    assert_text "Try again"
    assert_includes title.text, "Could not save"
  end

  test "polite maps to a status region" do
    render_inline(DS::Alert.new(message: "Syncing", live: :polite))

    assert_selector "[role='status']", text: "Syncing"
  end

  test "an unknown variant falls back to info" do
    render_inline(DS::Alert.new(message: "Hello", variant: :neon))

    assert_selector ".sr-only", text: "#{I18n.t("ds.alert.variants.info")}:"
  end
end
