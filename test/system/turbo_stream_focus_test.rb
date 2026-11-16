require "application_system_test_case"

# One animation frame after a Turbo stream arrives, Turbo puts focus back on the
# field that had it, for a field the stream replaced. Turbo 8.0.23 did that also
# when a person had moved to another field in that frame: a click on the new
# transaction's amount as the description's suggestions arrived went back to the
# description (app/javascript/utils/turbo_stream_focus.js).
#
# The tests hold the page's animation frames to put the click inside that frame,
# where a busy machine puts it only now and then.
class TurboStreamFocusTest < ApplicationSystemTestCase
  OPERATOR_ROW = "button[aria-label='#{I18n.t("shared.money_field.operator_add")}']".freeze

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
    visit new_transaction_url
  end

  test "a click on the amount as the description's suggestions arrive keeps focus on the amount" do
    find_field("entry_name").click
    # Closed, so the click on the amount cannot land on the list
    find_field("entry_name").send_keys(:escape)
    assert_no_selector "[role='listbox']", visible: true
    assert_equal "entry_name", active_element_id

    render_suggestions_holding_frames "Groceries"
    find_field("entry[amount]").click
    release_frames

    assert_equal "entry_amount", active_element_id
    assert_selector OPERATOR_ROW
  end

  test "a stream that replaces the field with focus still gives focus to the new field" do
    find_field("entry[amount]").click
    old_field = find_field("entry[amount]").native

    hold_frames
    page.execute_script(<<~JS)
      Turbo.renderStreamMessage(`<turbo-stream action="replace" target="entry_amount"><template><input id="entry_amount" type="text" name="entry[amount]"></template></turbo-stream>`)
    JS
    release_frames

    assert_not_equal old_field, find_field("entry[amount]").native
    assert_equal "entry_amount", active_element_id
  end

  private
    def active_element_id
      page.evaluate_script("document.activeElement.id")
    end

    # Queues every requestAnimationFrame callback until release_frames.
    def hold_frames
      page.execute_script(<<~JS)
        const request = window.requestAnimationFrame
        const held = []
        window.requestAnimationFrame = (callback) => held.push(callback)
        window.releaseHeldFrames = () => {
          window.requestAnimationFrame = request
          held.forEach((callback) => request(callback))
        }
      JS
    end

    # The description's suggestions, as the combobox fetches them, rendered as
    # they arrive while frames are held.
    def render_suggestions_holding_frames(query)
      url = name_suggestions_transactions_path(nature: "outflow", for_id: "entry_name", q: query, format: :turbo_stream)
      hold_frames
      page.evaluate_async_script(<<~JS, url)
        const [url, done] = arguments
        fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" } })
          .then((response) => response.text())
          .then((html) => { Turbo.renderStreamMessage(html); done() })
      JS
    end

    # Runs the held frames, then waits one more frame and a task for what they started.
    def release_frames
      page.evaluate_async_script(<<~JS)
        const done = arguments[0]
        window.releaseHeldFrames()
        requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(done)))
      JS
    end
end
