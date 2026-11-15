class SparklineComponentPreview < ViewComponent::Preview
  # @display container_classes max-w-[400px]
  def default
    render DS::Sparkline.new(series: series([ 120, 120, 0, 135, 120, 150, 120, 120, 0, 140, 120, 125 ]), aria_label: "Payments over the last 12 months")
  end

  # @display container_classes max-w-[400px]
  def destructive
    render DS::Sparkline.new(series: series([ 40, 55, 30, 80, 65, 90 ]), aria_label: "Spending trend", css: "w-full text-destructive")
  end

  private
    def series(values)
      start = Date.current.beginning_of_month - (values.size - 1).months
      values.each_with_index.map { |value, index| [ start + index.months, value ] }
    end
end
