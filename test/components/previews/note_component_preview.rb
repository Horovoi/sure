class NoteComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[480px]
  def default
    render DS::Note.new(title: "How long we keep this") do
      content_tag(:p, "Standing explanatory copy sits in a quiet inset panel.")
    end
  end

  # @display container_classes max-w-[480px]
  def without_title
    render DS::Note.new do
      content_tag(:p, "A note can also be a single paragraph.")
    end
  end
end
