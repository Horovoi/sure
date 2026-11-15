class ExpandToggleComponentPreview < ViewComponent::Preview
  # The static shell only: the page script that owns the <details> group swaps
  # the icons and the label.
  def default
    render DS::ExpandToggle.new(expand_label: "Expand all", collapse_label: "Collapse all", data: { preview_expand_all: true })
  end
end
