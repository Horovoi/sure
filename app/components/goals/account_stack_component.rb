class Goals::AccountStackComponent < ApplicationComponent
  def initialize(accounts:, goal: nil, max: 3)
    @accounts = accounts
    @goal = goal
    @max = max
  end

  def shown
    @accounts.first(@max)
  end

  def extra_count
    (@accounts.size - @max).clamp(0..)
  end

  # Goal#account_color, so the stack on the card matches the form and the
  # funding breakdown on the show page
  def color_for(account)
    @goal ? @goal.account_color(account) : Goal.color_for_name(account.name)
  end
end
