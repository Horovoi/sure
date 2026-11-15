class SearchInputComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[400px]
  def standalone
    render DS::SearchInput.new(placeholder: "Search currencies")
  end

  # Inside a panel that draws its own focus chrome with focus-ring-within.
  # @display container_classes max-w-[400px]
  def embedded
    render_with_template
  end
end
