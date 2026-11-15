class StyledFormBuilder < ActionView::Helpers::FormBuilder
  # Rails 8 renamed two field helpers, text_area to textarea and check_box to checkbox,
  # and kept the old names as aliases of the base methods. Both spellings of the
  # non-text helpers are left out here, and text_area is aliased below so that
  # form.text_area stays styled.
  NON_TEXT_FIELD_HELPERS = [ :label, :check_box, :checkbox, :radio_button, :fields_for, :fields, :hidden_field, :file_field ].freeze
  class_attribute :text_field_helpers, default: field_helpers - NON_TEXT_FIELD_HELPERS

  text_field_helpers.each do |selector|
    define_method(selector) do |method, options = {}|
      form_options = options.slice(:label, :label_tooltip, :inline, :container_class, :required)
      html_options = options.except(:label, :label_tooltip, :inline, :container_class)

      build_field(method, form_options, html_options) do |merged_options|
        super(method, merged_options)
      end
    end
  end

  alias_method :text_area, :textarea

  def radio_button(method, tag_value, options = {})
    merged_options = { class: "form-field__radio" }.merge(options)
    super(method, tag_value, merged_options)
  end

  def select(method, choices, options = {}, html_options = {})
    field_options = normalize_options(options, html_options)

    build_field(method, field_options, html_options) do |merged_html_options|
      super(method, choices, options, merged_html_options)
    end
  end

  # A native <select> by default. Passing `variant:` (:simple, :logo, :badge)
  # or `searchable: true` renders the DS::Select listbox instead, the way
  # upstream call sites ask for it. The native element stays the default
  # because it keeps `required` validation and the browser's own keyboard
  # handling, which forms like the account pickers rely on.
  def collection_select(method, collection, value_method, text_method, options = {}, html_options = {})
    if options.key?(:variant) || options[:searchable]
      return ds_collection_select(method, collection, value_method, text_method, options, html_options)
    end

    field_options = normalize_options(options, html_options)

    build_field(method, field_options, html_options) do |merged_html_options|
      super(method, collection, value_method, text_method, options, merged_html_options)
    end
  end

  def money_field(amount_method, options = {})
    @template.render partial: "shared/money_field", locals: {
      form: self,
      amount_method:,
      currency_method: options[:currency_method] || :currency,
      **options
    }
  end

  def toggle(method, options = {}, checked_value = "1", unchecked_value = "0")
    field_id = field_id(method)
    field_name = field_name(method)
    checked = object ? object.send(method) : options[:checked]

    @template.render(
      DS::Toggle.new(
        id: field_id,
        name: field_name,
        checked: checked,
        disabled: options[:disabled],
        checked_value: checked_value,
        unchecked_value: unchecked_value,
        **options
      )
    )
  end

  def submit(value = nil, options = {})
    value, options = nil, value if value.is_a?(Hash)
    value ||= submit_default_value

    @template.render(
      DS::Button.new(
        text: value,
        type: "submit",
        data: (options[:data] || {}).merge({ turbo_submits_with: "Submitting..." }),
        full_width: true
      )
    )
  end

  private
    def ds_collection_select(method, collection, value_method, text_method, options, html_options)
      selected_value =
        if options.key?(:selected)
          options[:selected]
        elsif @object.respond_to?(method)
          @object.public_send(method)
        end
      placeholder = options[:prompt] || options[:include_blank] || options[:placeholder] || I18n.t("ds.select.default_label")

      @template.render(
        DS::Select.new(
          form: self,
          method: method,
          items: collection.map { |item| { value: item.public_send(value_method), label: item.public_send(text_method), object: item } },
          selected: selected_value,
          placeholder: placeholder,
          searchable: options.fetch(:searchable, false),
          menu_placement: options[:menu_placement],
          variant: options.fetch(:variant, :simple),
          include_blank: options[:include_blank],
          label: options[:label],
          container_class: options[:container_class],
          scoped_ids: options.fetch(:scoped_ids, false),
          disabled: html_options[:disabled],
          html_options: html_options
        )
      )
    end

    def build_field(method, options = {}, html_options = {}, &block)
      if options[:inline] || options[:label] == false
        return yield({ class: "form-field__input" }.merge(html_options))
      end

      label_element = build_label(method, options)
      field_element = yield({ class: "form-field__input" }.merge(html_options))

      container_classes = [ "form-field", options[:container_class] ].compact

      @template.tag.div class: container_classes do
        if options[:label_tooltip]
          @template.tag.div(class: "form-field__header") do
            label_element +
            @template.tag.div(class: "form-field__actions") do
              build_tooltip(options[:label_tooltip])
            end
          end +
          @template.tag.div(class: "form-field__body") do
            field_element
          end
        else
          @template.tag.div(class: "form-field__body") do
            label_element + field_element
          end
        end
      end
    end

    def normalize_options(options, html_options)
      options.merge(required: options[:required] || html_options[:required])
    end

    def build_label(method, options)
      return "".html_safe unless options[:label]

      label_text = options[:label]

      if options[:required]
        label_text = @template.safe_join([
          label_text == true ? method.to_s.humanize : label_text,
          @template.tag.span("*", class: "text-red-500 ml-0.5")
        ])
      end

      return label(method, class: "form-field__label") if label_text == true
      label(method, label_text, class: "form-field__label")
    end

    def build_tooltip(tooltip_text)
      return nil unless tooltip_text

      @template.tag.div(data: { controller: "tooltip" }) do
        @template.safe_join([
          @template.icon("help-circle", size: "sm", color: "default", class: "cursor-help"),
          @template.tag.div(tooltip_text, role: "tooltip", data: { tooltip_target: "tooltip" }, class: "tooltip bg-gray-700 text-sm p-2 rounded w-64 text-white")
        ])
      end
    end
end
