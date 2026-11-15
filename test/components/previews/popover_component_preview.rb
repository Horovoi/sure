class PopoverComponentPreview < ViewComponent::Preview
  # A positioned panel for mixed content (forms, pickers, account menus).
  # Use DS::Menu instead for a flat list of actions.
  def icon
    render DS::Popover.new(variant: "icon", aria_label: "Filters") do |popover|
      popover.with_custom_content { panel_body }
    end
  end

  def button
    render DS::Popover.new(variant: "button", placement: "bottom-start") do |popover|
      popover.with_button(text: "Open panel", variant: "secondary")
      popover.with_header { content_tag(:div, content_tag(:h3, "Panel header", class: "font-medium text-primary"), class: "p-3") }
      popover.with_custom_content { panel_body }
    end
  end

  def avatar
    render DS::Popover.new(variant: "avatar", initials: "MH", aria_label: "Account menu") do |popover|
      popover.with_custom_content { panel_body }
    end
  end

  private
    def panel_body
      content_tag(:div, class: "p-3 space-y-2 w-64") do
        safe_join([
          content_tag(:label, "Search", class: "block text-xs text-secondary"),
          tag.input(type: "text", class: "w-full rounded-md border border-secondary bg-container px-2 py-1 text-sm focus-ring"),
          content_tag(:p, "Arbitrary content, not a role=menu list.", class: "text-sm text-secondary")
        ])
      end
    end
end
