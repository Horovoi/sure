# frozen_string_literal: true

# `DS::IconPicker` is a shared, searchable lucide-icon grid.
#
# `method` is a parameter because the backing columns can differ
# (`categories.lucide_icon` today, a goal's icon later).
#
# Each radio is wired to a colour-and-icon Stimulus controller on an ancestor
# element, which tints the chosen icon and copies it into the preview. Upstream
# calls that controller `color-icon-picker`; in this app the category form's
# controller is `category`, which has the same targets and actions. Pass
# `picker_controller:` to target another one.
class DS::IconPicker < DesignSystemComponent
  DEFAULT_PICKER_CONTROLLER = "category"

  attr_reader :form, :method, :icons, :placeholder, :picker_controller

  def initialize(form:, method:, icons:, placeholder: nil, picker_controller: DEFAULT_PICKER_CONTROLLER)
    @form = form
    @method = method
    @icons = icons
    @placeholder = placeholder || I18n.t("ds.icon_picker.search_placeholder")
    @picker_controller = picker_controller
  end

  # Data attributes for each icon radio, in the picker controller's namespace.
  def radio_data
    {
      action: "change->#{picker_controller}#handleIconChange change->#{picker_controller}#handleIconColorChange",
      "#{picker_controller.underscore}_target": "icon"
    }
  end
end
