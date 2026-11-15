class DialogComponentPreview < ViewComponent::Preview
  # @param show_overflow toggle
  def modal(show_overflow: false)
    render DS::Dialog.new(variant: "modal") do |dialog|
      dialog.with_header(title: "Sample modal title")

      dialog.with_body do
        "Welcome to Sure!  This is some test modal content."
      end

      dialog.with_action(cancel_action: true, text: "Cancel", variant: "outline")
      dialog.with_action(text: "Submit")

      if show_overflow
        content_tag(:div, class: "p-4 font-semibold h-[800px] bg-surface-inset") do
          "Example of overflow content"
        end
      end
    end
  end

  # @param show_overflow toggle
  def drawer(show_overflow: false)
    render DS::Dialog.new(variant: "drawer") do |dialog|
      dialog.with_header(title: "Drawer title")

      dialog.with_body do
        dialog.with_section(title: "Section 1", open: true) do
          content_tag(:div, "Section 1 content", class: "p-2")
        end

        dialog.with_section(title: "Section 2", open: true) do
          content_tag(:div, "Section 2 content", class: "p-2")
        end
      end

      dialog.with_action(text: "Example action")

      if show_overflow
        content_tag(:div, class: "p-4 font-semibold h-[800px] bg-surface-inset") do
          "Example of overflow content"
        end
      end
    end
  end

  # A drawer on lg, a centred modal on phones.
  def responsive
    render DS::Dialog.new(frame: "drawer", responsive: true) do |dialog|
      dialog.with_header(title: "Responsive dialog", meta: "Last 30 days")

      dialog.with_body do
        content_tag(:p, "Tab and Shift+Tab stay inside the dialog; closing it returns focus to the opener.", class: "text-sm")
      end
    end
  end

  # The fullscreen chart shape.
  def expanded
    render DS::Dialog.new(width: "expanded", heading_level: 3) do |dialog|
      dialog.with_header(title: "Expanded dialog")

      dialog.with_body do
        content_tag(:div, "Wide content", class: "h-64 bg-surface-inset rounded-lg p-4")
      end
    end
  end
end
