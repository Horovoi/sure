class DS::Dialog < DesignSystemComponent
  # `meta:` adds a small chip after the title (the fullscreen chart dialogs show
  # their period there; `meta_id:` lets a controller update it). With neither a
  # title nor meta, the block content and the close button share one row.
  # `custom_header: true` leaves the close button out, for headers that place
  # `close_button` themselves.
  renders_one :header, ->(title: nil, subtitle: nil, meta: nil, meta_id: nil, custom_header: false, **opts, &block) do
    content_tag(:header, class: "px-4 flex flex-col gap-2", **opts) do
      close_icon = close_button unless custom_header

      if title.present? || meta.present?
        title_div = content_tag(:div, class: "flex items-center justify-between gap-2") do
          # `id: title_id` lets the host `<dialog>` reference the title via
          # `aria-labelledby`, so AT users hear the title when focus lands in
          # the dialog. `heading_level:` picks h2, h3 and so on.
          title_el = content_tag("h#{heading_level}", title, id: title_id, class: class_names("font-medium text-primary", drawer? ? "text-lg" : "")) if title.present?
          meta_chip = content_tag(:span, meta, id: meta_id, class: "ml-2 inline-flex items-center rounded-full border border-secondary text-secondary text-xs font-medium px-2 py-0.5") if meta.present?
          safe_join([ title_el, meta_chip, close_icon ].compact)
        end

        subtitle_el = content_tag(:p, subtitle, class: "text-sm text-secondary") if subtitle
        block_content = capture(&block) if block
        safe_join([ title_div, subtitle_el, block_content ].compact)
      else
        block_content = capture(&block) if block
        content_tag(:div, class: "flex items-start justify-between gap-2") do
          safe_join([ block_content, close_icon ].compact)
        end
      end
    end
  end

  renders_one :body

  renders_many :actions, ->(cancel_action: false, **button_opts) do
    merged_opts = if cancel_action
      button_opts.merge(type: "button", data: { action: "DS--dialog#close" })
    else
      button_opts
    end

    render DS::Button.new(**merged_opts)
  end

  renders_many :sections, ->(title:, **disclosure_opts, &block) do
    render DS::Disclosure.new(title: title, align: :right, **disclosure_opts) do
      block.call
    end
  end

  attr_reader :variant, :auto_open, :reload_on_close, :width, :disable_frame, :content_class, :disable_click_outside, :opts, :responsive, :scrollable, :heading_level, :title_id

  VARIANTS = %w[modal drawer].freeze
  # `expanded` is the "give this cramped thing the whole screen" shape: it keeps
  # a sliver of viewport margin, unlike `full`, and caps out so wide tables and
  # charts don't stretch unreadably on ultrawide displays. The 96vw only applies
  # from `lg`, where the dialog drops its `mx-3` gutter; below that the base
  # `w-full` plus the gutter already fits. `xl` is the fork's fullscreen chart
  # width.
  WIDTHS = {
    sm: "lg:max-w-[300px]",
    md: "lg:max-w-[550px]",
    lg: "lg:max-w-[700px]",
    xl: "lg:max-w-[92vw]",
    full: "lg:max-w-full",
    expanded: "lg:!w-[96vw] max-w-[1650px]"
  }.freeze
  VALID_HEADING_LEVELS = (1..6).freeze

  # `disable_click_outside: true` keeps the dialog open when the backdrop is
  # clicked (for forms that would lose typed input). There is no per-user
  # preference: the default is always false.
  def initialize(variant: "modal", auto_open: true, reload_on_close: false, width: "md", frame: nil, disable_frame: false, content_class: nil, disable_click_outside: false, responsive: false, scrollable: true, heading_level: 2, **opts)
    unless heading_level.is_a?(Integer) && VALID_HEADING_LEVELS.cover?(heading_level)
      raise ArgumentError, "heading_level must be an Integer between 1 and 6, got: #{heading_level.inspect}"
    end

    @variant = variant.to_sym
    @auto_open = auto_open
    @reload_on_close = reload_on_close
    @width = width.to_sym
    @frame = frame
    @disable_frame = disable_frame
    @content_class = content_class
    @disable_click_outside = disable_click_outside
    @responsive = responsive
    @scrollable = scrollable
    @heading_level = heading_level
    @title_id = "dialog-title-#{SecureRandom.hex(4)}"
    @opts = opts
  end

  def frame
    @frame || variant
  end

  # Caller must "opt-out" of using the default turbo-frame based on the variant
  def wrapper_element(&block)
    if disable_frame
      content_tag(:div, &block)
    else
      content_tag("turbo-frame", id: frame, &block)
    end
  end

  def dialog_outer_classes
    variant_classes = if drawer?
      # On phones the drawer is anchored to the top, so a growing body pushes it
      # downward; from lg it is a classic right-hand drawer.
      "items-start justify-center lg:items-end lg:justify-end"
    elsif responsive?
      "items-center justify-center lg:items-end lg:justify-end"
    else
      "items-center justify-center"
    end

    class_names(
      "flex h-full w-full",
      variant_classes
    )
  end

  def dialog_inner_classes
    variant_classes = if drawer?
      # Vertical insets on phones match the modal spacing and keep the drawer
      # inside the viewport; from lg it is full height.
      "lg:w-[550px] lg:h-full mt-6 mb-4 lg:my-0 max-h-[calc(100svh-1.75rem)]"
    elsif responsive?
      "max-h-full lg:h-full lg:w-[550px]"
    else
      class_names(
        "max-h-full",
        WIDTHS[width]
      )
    end

    class_names(
      # The max width keeps the horizontal margins from overflowing a phone.
      "flex flex-col bg-container rounded-xl shadow-border-xs mx-3 lg:mx-0 w-full max-w-[calc(100vw-1.5rem)] overflow-hidden",
      variant_classes,
      content_class
    )
  end

  def merged_opts
    merged_opts = opts.dup
    data = merged_opts.delete(:data) || {}

    data[:controller] = [ "DS--dialog", "hotkey", data[:controller] ].compact.join(" ")
    data[:DS__dialog_auto_open_value] = auto_open
    data[:DS__dialog_reload_on_close_value] = reload_on_close
    data[:DS__dialog_disable_click_outside_value] = disable_click_outside
    # mousedown, not click: a text selection dragged from inside the panel and
    # released over the backdrop must not close the dialog.
    data[:action] = [ "mousedown->DS--dialog#clickOutside", data[:action] ].compact.join(" ")
    data[:hotkey] = "esc:DS--dialog#close"
    # Fetched into a frame over the page, the dialog is left out of Turbo's
    # cached copy of that page, or Back brings it back: stray if it was still
    # open, opened again if it was closed. Visited directly, it is the page and
    # stays. Turbo also caches the live page right after any frame visit with
    # data-turbo-action renders, and that removes these dialogs, so don't open
    # one that way or make such a visit while one is open.
    data[:turbo_temporary] = true if helpers.turbo_frame_request_id == frame.to_s
    merged_opts[:data] = data

    merged_opts
  end

  def drawer?
    variant == :drawer
  end

  def responsive?
    @responsive
  end

  # Reachable by keyboard and named for screen readers. shrink-0 keeps its
  # square beside a long title in a custom header.
  def close_button
    render DS::Button.new(
      variant: "icon",
      size: :sm,
      class: "ml-auto shrink-0",
      icon: "x",
      title: I18n.t("ds.dialog.close"),
      aria_label: I18n.t("ds.dialog.close"),
      data: { action: "DS--dialog#close" }
    )
  end
end
