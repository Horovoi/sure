module Assistant::Configurable
  extend ActiveSupport::Concern

  # The byte-stable half of the system prompt. Everything volatile (date, currency, accounts, categories) lives
  # in the trailing Session context block, because providers cache and discount an exactly repeated prefix: one
  # changed byte mid-prompt invalidates everything after it. Keep this text free of interpolation.
  #
  # The function rules stay neutral about what a function does (reads or writes): the chat gets every tool, and
  # rules for a kind of tool are added here as their own section.
  STATIC_INSTRUCTIONS = <<~PROMPT.freeze
    ## Your identity

    You are a friendly financial assistant for an open source personal finance application called "Sure", which is short for "Sure Finances".

    ## Your purpose

    You help users understand and manage their financial data: accounts, transactions, income, expenses, net worth, budgets, forecasting and more.

    ## How to handle a request

    First classify the request, then act:

    - CHAT: greetings, thanks, or general personal-finance concepts. Answer directly. Do not call functions.
    - LOOKUP: one specific fact (a balance, a total, one transaction). Call the single most specific function, then answer.
    - ANALYSIS: trends, comparisons, or multi-part questions. Decide which functions you need before calling any, and make independent calls in the same round.

    ### Function calling rules

    - Use the functions available to you to get the user's financial data and enhance your responses.
    - Reuse data already present in this conversation or in the Session context below instead of calling a function again for it. Exception: always fetch again when the data may have changed (for example after something was created or updated) or when the user asks for a different time range or more detail.
    - Prefer the most specific function: use the income statement or balance sheet for totals and trends, and list transactions only to find or inspect individual ones.
    - For functions that require dates, use today's date from the Session context as your reference point.
    - If a function result contains an "error", correct the arguments and retry once. Never repeat an identical failing call.
    - You have a limited number of function rounds per answer. When you are asked to answer without functions, answer with what you have gathered and say what is missing.
    - Never mention internal function names in your responses. Describe what you did in plain language ("I checked your bills", not "I called get_bills").
    - If you suspect that you do not have enough data to answer accurately, be transparent about it and state exactly what the data you present represents and its context (date range, account, and so on).

    ### Response rules

    - Provide ONLY the most important numbers and insights
    - Eliminate all unnecessary words and context
    - Ask follow-up questions to keep the conversation going. Help educate the user about their own data and entice them to ask more questions.
    - Do NOT add introductions or conclusions
    - Do NOT apologize or explain limitations
    - Format all responses in markdown
    - Format monetary values in the user's preferred currency and dates in the user's preferred format, both given in the Session context below. When no currency is specified, use the preferred currency.

    ### Rules about financial advice

    You should focus on educating the user about personal finance using their own data so they can make informed decisions.

    - Do not tell the user to buy or sell specific financial products or investments.
    - Do not make assumptions about the user's financial situation. Use the functions available to get the data you need.
  PROMPT

  # The context lists accounts and categories by name up to these counts, and only counts them beyond, so the
  # volatile tail of the prompt stays cheap.
  ACCOUNTS_ROSTER_LIMIT = 25
  CATEGORY_NAMES_LIMIT = 60

  EXCHANGE_RATE_SOURCES = {
    "nbu" => "official daily rates of the National Bank of Ukraine (NBU)",
    "twelve_data" => "daily rates from Twelve Data",
    "yahoo_finance" => "daily rates from Yahoo Finance"
  }.freeze

  class_methods do
    def config_for(chat)
      {
        instructions: instructions_for(chat.user),
        functions: default_functions
      }
    end

    # The static prefix, then the user's session context
    def instructions_for(user)
      "#{Assistant::Configurable::STATIC_INSTRUCTIONS}\n#{session_context(user)}"
    end

    private
      def default_functions
        Assistant.function_classes
      end

      def session_context(user)
        family = user.family
        currency = Money::Currency.new(family.currency)

        <<~PROMPT
          ## Session context

          - Today's date: #{today_for(family).iso8601}#{" (time zone #{family.timezone})" if family.timezone.present?}
          - Date format: #{family.date_format}
          - Preferred currency: #{currency.iso_code} (symbol #{currency.symbol}, precision #{currency.default_precision}, format #{currency.default_format}, separator "#{currency.separator}", delimiter "#{currency.delimiter}")
          - Exchange rates: amounts in other currencies are converted to #{currency.iso_code} with #{exchange_rate_source}.
          - #{month_context(family)}
          #{accounts_context(family)}#{categories_context(family)}
        PROMPT
      end

      # Today in the family's time zone, wherever this runs (a web request or a job)
      def today_for(family)
        zone = family.timezone.presence && ActiveSupport::TimeZone[family.timezone]
        zone ? zone.today : Date.current
      end

      def exchange_rate_source
        EXCHANGE_RATE_SOURCES.fetch(Setting.exchange_rate_provider.to_s, "the configured daily exchange rates")
      end

      def month_context(family)
        if family.fiscal_month_enabled?
          "Months: budgets and monthly totals use fiscal months that start on day #{family.fiscal_start_day} of each calendar month. The current fiscal month started on #{family.budget_period_start_for(today_for(family)).iso8601}."
        else
          "Months: budgets and monthly totals use calendar months."
        end
      end

      def accounts_context(family)
        accounts = family.accounts.visible.alphabetically.to_a
        return "" if accounts.empty?

        all_manual = family.accounts.visible.manual.count == accounts.size
        manual_note = all_manual ? "All accounts are manual (no bank connections): balances and transactions are as current as the user's last entry or import.\n\n" : ""

        if accounts.size > ACCOUNTS_ROSTER_LIMIT
          counts = accounts.group_by(&:accountable_type).map { |type, group| "#{group.size} #{type}" }.join(", ")

          <<~CONTEXT

            ### Accounts

            #{manual_note}#{accounts.size} accounts: #{counts}. Use the accounts function for the list.
          CONTEXT
        else
          lines = accounts.map do |account|
            "- #{account.name}: #{account.accountable_type}, #{account.classification}, #{account.balance_money.format}"
          end

          <<~CONTEXT

            ### Accounts

            #{manual_note}#{lines.join("\n")}
          CONTEXT
        end
      end

      def categories_context(family)
        names = family.categories.alphabetically.pluck(:name)
        return "" if names.empty?

        if names.size > CATEGORY_NAMES_LIMIT
          <<~CONTEXT

            ### Categories

            #{names.size} categories.
          CONTEXT
        else
          <<~CONTEXT

            ### Categories

            #{(names + [ "Uncategorized" ]).join(", ")}
          CONTEXT
        end
      end
  end
end
