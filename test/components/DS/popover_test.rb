require "test_helper"

class DS::PopoverTest < ViewComponent::TestCase
  test "renders the custom content inside the panel" do
    render_inline(DS::Popover.new(variant: "button")) do |popover|
      popover.with_button(text: "Open")
      popover.with_custom_content { "Panel body" }
    end

    assert_selector "[data-controller='DS--popover']"
    assert_selector "[data-ds--popover-target='content']", text: "Panel body", visible: :all
    assert_no_selector "[data-ds--popover-target='frame']", visible: :all
    assert_no_selector "[data-ds--popover-frame-src-value]"
  end

  test "a lazy frame panel ships an empty slot and the frame details for the controller" do
    render_inline(DS::Popover.new(variant: "button", frame_id: "tag_dropdown", frame_src: "/tag/dropdown?entry_id=1")) do |popover|
      popover.with_button(text: "Open")
    end

    assert_selector "[data-controller='DS--popover'][data-ds--popover-frame-id-value='tag_dropdown'][data-ds--popover-frame-src-value='/tag/dropdown?entry_id=1']"
    assert_selector "[data-ds--popover-target='frame']", visible: :all
    assert_no_selector "turbo-frame", visible: :all
  end

  test "frame id and src must come together" do
    error = assert_raises(ArgumentError) { DS::Popover.new(frame_id: "tag_dropdown") }
    assert_match(/frame_id and frame_src/, error.message)
    error = assert_raises(ArgumentError) { DS::Popover.new(frame_src: "/tag/dropdown") }
    assert_match(/frame_id and frame_src/, error.message)
  end

  test "the icon trigger is a named button wired to the panel" do
    render_inline(DS::Popover.new(variant: "icon", aria_label: "Filters")) do |popover|
      popover.with_custom_content { "Panel body" }
    end

    panel_id = page.find("[data-ds--popover-target='content']", visible: :all)[:id]
    assert_match(/\Apopover-\h{8}\z/, panel_id)
    assert_selector "button[type='button'][data-ds--popover-target='button'][aria-label='Filters'][aria-haspopup='dialog'][aria-expanded='false'][aria-controls='#{panel_id}']"
    assert_no_selector "button[aria_label]"
  end

  test "the avatar trigger falls back to a default accessible name" do
    render_inline(DS::Popover.new(variant: "avatar", initials: "MH")) do |popover|
      popover.with_custom_content { "Panel body" }
    end

    assert_selector "button.focus-ring[data-ds--popover-target='button'][aria-label='Open menu'][aria-haspopup='dialog']"
  end

  test "a block button slot keeps the caller's markup and adds the trigger wiring" do
    render_inline(DS::Popover.new(variant: "button")) do |popover|
      popover.with_button(class: "custom-trigger") { "Account" }
      popover.with_custom_content { "Panel body" }
    end

    assert_selector "button.custom-trigger[type='button'][data-ds--popover-target='button'][aria-haspopup='dialog']", text: "Account"
  end

  test "rejects an unknown variant" do
    assert_raises(ArgumentError) { DS::Popover.new(variant: "floating") }
  end
end
