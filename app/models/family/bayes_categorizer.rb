# Local naive-Bayes transaction categorizer. Needs no provider and sends nothing
# anywhere.
#
# Trains a multinomial naive-Bayes model (Laplace add-1 smoothing) on the family's
# categorized transactions, then classifies uncategorized ones from the same text
# the LLM categorizer reads (entry name, notes and merchant name). The tokenizer is
# Unicode-aware, so Ukrainian and other non-Latin descriptions train and match.
#
# Training uses only categories a person chose: set by the user or by one of their
# rules. Categories the AI or this classifier guessed (lock source "ai" or "bayes")
# are left out, so a guess never teaches the next guess. Transfers and other
# non-spending kinds are left out of both training and classification.
#
# A category it sets carries a soft "bayes" lock (Enrichable::SOFT_LOCK_SOURCES):
# any rule may replace it, and a user edit turns it into a user lock.
class Family::BayesCategorizer
  CONFIDENCE_THRESHOLD = 0.7
  MIN_TRAINING_TRANSACTIONS = 20
  MIN_CATEGORIES = 2
  # The whole training set is held in memory, so it is capped rather than loading a
  # long-lived family's entire history on every run. The most recent transactions
  # are also the most representative of current spending.
  MAX_TRAINING_TRANSACTIONS = 5_000

  CATEGORIZABLE_KINDS = %w[standard one_time].freeze
  AUTOMATIC_CATEGORY_SOURCES = %w[ai bayes].freeze
  LOCK_SOURCE = "bayes".freeze

  # Letters and digits of any script, keeping an apostrophe inside a word
  # (Ukrainian "м'ясо", English "o'reilly") as one token
  TOKEN_PATTERN = /[[:alnum:]]+(?:['’ʼ][[:alnum:]]+)*/
  APOSTROPHES = "’ʼ".freeze

  # categorized_ids: transaction ids the model labeled at or above the threshold
  # (whether or not the write changed anything). modified_count: how many of those
  # writes changed the category.
  Result = Data.define(:categorized_ids, :modified_count)

  def self.tokenize(text)
    text.to_s.scrub("").unicode_normalize(:nfkc).downcase
        .scan(TOKEN_PATTERN)
        .map { |token| token.tr(APOSTROPHES, "''") }
        .select { |token| token.length > 1 }
  end

  def initialize(family, training_limit: MAX_TRAINING_TRANSACTIONS)
    @family = family
    @training_limit = training_limit
  end

  # Refuses to classify until there is a real signal to train on
  def enough_training_data?
    training_transactions.size >= MIN_TRAINING_TRANSACTIONS &&
      class_models.size >= MIN_CATEGORIES
  end

  # [category_id, confidence] for the most likely category, or nil when the model
  # is not trained yet or no category clears the confidence threshold.
  def classify(transaction)
    return nil unless enough_training_data?

    log_scores = log_scores_for(tokens_for(transaction))
    return nil if log_scores.empty?

    category_id, _score = log_scores.max_by { |_, score| score }
    confidence = softmax(log_scores.values).max
    return nil if confidence < CONFIDENCE_THRESHOLD

    [ category_id, confidence ]
  end

  # Categorizes every uncategorized, enrichable, spending transaction among
  # transaction_ids (ids, or a relation selecting them) whose best category clears
  # the threshold. An empty Result when the training guard fails.
  def classify_and_apply(transaction_ids)
    empty = Result.new(categorized_ids: [], modified_count: 0)
    return empty unless enough_training_data?

    categorized_ids = []
    modified_count = 0

    candidates(transaction_ids).find_each do |transaction|
      category_id, confidence = classify(transaction)
      next if category_id.nil?

      categorized_ids << transaction.id
      was_modified = transaction.enrich_attribute(:category_id, category_id, source: LOCK_SOURCE, metadata: { confidence: confidence.round(4) })
      next unless was_modified

      transaction.lock_attr!(:category_id, source: LOCK_SOURCE)
      modified_count += 1
    end

    Result.new(categorized_ids: categorized_ids, modified_count: modified_count)
  end

  private
    attr_reader :family, :training_limit

    def candidates(transaction_ids)
      categorizable(family.transactions)
        .where(id: transaction_ids, category_id: nil)
        .enrichable(:category_id)
        .includes(:merchant, :entry)
    end

    def categorizable(scope)
      scope.visible.where(kind: CATEGORIZABLE_KINDS)
    end

    # Same signal as AutoCategorizer#transactions_input, so the two categorizers
    # agree on what text a transaction speaks
    def tokens_for(transaction)
      self.class.tokenize([ transaction.entry&.name, transaction.entry&.notes, transaction.merchant&.name ].compact.join(" "))
    end

    def training_transactions
      @training_transactions ||= categorizable(family.transactions)
        .where.not(category_id: nil)
        .where.not(automatic_category_sql)
        .includes(:merchant, :entry)
        .order(created_at: :desc, id: :desc)
        .limit(training_limit)
        .to_a
    end

    # A category whose lock says the AI or this classifier set it
    def automatic_category_sql
      connection = Transaction.connection
      sources = AUTOMATIC_CATEGORY_SOURCES.map { |source| connection.quote(source) }.join(", ")
      Arel.sql("COALESCE(transactions.locked_attributes -> 'category_id' ->> 'source', '') IN (#{sources})")
    end

    # Per-category token-count models: { category_id => { total:, counts: } }.
    # A transaction with no usable token adds nothing.
    def class_models
      @class_models ||= training_transactions.group_by(&:category_id).filter_map do |category_id, txns|
        counts = Hash.new(0)
        txns.each { |txn| tokens_for(txn).each { |token| counts[token] += 1 } }
        next if counts.empty?

        [ category_id, { total: counts.values.sum, counts: counts } ]
      end.to_h
    end

    def vocabulary
      @vocabulary ||= Set.new(class_models.values.flat_map { |model| model[:counts].keys })
    end

    # Multinomial NB log-score per category with Laplace add-1 smoothing and a
    # uniform prior (constant across classes, so it drops out of the softmax):
    # log(P(c)) + sum over tokens of log((count_t + 1) / (total_c + |V|))
    def log_scores_for(tokens)
      # Only tokens the model has seen. An unknown token's smoothed likelihood is
      # 1 / (total_c + |V|), which varies with each class's own size, so a wholly new
      # description would gain confidence for whichever category has the smallest
      # corpus. With no known token there is nothing to score and the transaction
      # falls through to the LLM.
      known_tokens = tokens.select { |token| vocabulary.include?(token) }
      return {} if known_tokens.empty? || class_models.empty?

      denominator = vocabulary.size
      prior = Math.log(1.0 / class_models.size)
      class_models.each_with_object({}) do |(category_id, model), scores|
        scores[category_id] = prior + known_tokens.sum do |token|
          Math.log((model[:counts][token] + 1).to_f / (model[:total] + denominator))
        end
      end
    end

    # Numerically stable softmax over the log-scores
    def softmax(scores)
      max = scores.max
      exps = scores.map { |score| Math.exp(score - max) }
      sum = exps.sum
      exps.map { |exp| exp / sum }
    end
end
