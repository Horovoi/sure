# frozen_string_literal: true

# A previous/next arrow that steps through periods (report months, budgets).
#
# With an `href` it is an icon link. Without one the period has no
# neighbour that way (the latest or earliest period), so it renders a greyed
# placeholder of the same size (subdued at half opacity, so it reads as off
# next to the grey active arrow): not a link, no hover, default cursor, and
# `aria-disabled` so assistive tech still announces the arrow. The box keeps
# its size either way, so the row beside it never moves.
#
# `hotkey:` binds a key through the hotkey controller (only while active).
# `shortcut_hint:` wraps the active arrow in a tooltip.
class DS::PeriodArrow < DesignSystemComponent
  DIRECTIONS = { previous: "chevron-left", next: "chevron-right" }.freeze

  attr_reader :direction, :href, :label, :hotkey, :shortcut_hint, :link_data

  def initialize(direction:, label:, href: nil, hotkey: nil, shortcut_hint: nil, data: {})
    raise ArgumentError, "direction: must be one of #{DIRECTIONS.keys.inspect}" unless DIRECTIONS.key?(direction.to_sym)

    @direction = direction.to_sym
    @label = label
    @href = href
    @hotkey = hotkey
    @shortcut_hint = shortcut_hint
    @link_data = data
  end

  def enabled?
    href.present?
  end

  def icon_name
    DIRECTIONS.fetch(direction)
  end

  def link
    aria = { label: label }
    data = link_data.merge(period_arrow: direction)
    if hotkey
      aria[:keyshortcuts] = hotkey
      data = data.merge(controller: "hotkey", hotkey: hotkey)
    end

    DS::Link.new(variant: "icon", icon: icon_name, href: href, aria: aria, data: data)
  end

  # The same box as an icon-only DS::Link of size md, so swapping one for the
  # other does not shift anything.
  def disabled_classes
    class_names(
      DS::Buttonish::SIZES.dig(:md, :icon_container_classes),
      DS::Buttonish::SIZES.dig(:md, :radius_classes),
      "inline-flex shrink-0 text-subdued opacity-50 cursor-default select-none"
    )
  end
end
