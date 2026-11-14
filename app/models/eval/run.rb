class Eval::Run < ApplicationRecord
  include AASM

  self.table_name = "eval_runs"

  belongs_to :dataset, class_name: "Eval::Dataset", foreign_key: :eval_dataset_id
  has_many :results, class_name: "Eval::Result", foreign_key: :eval_run_id, dependent: :destroy

  validates :provider, :model, :status, presence: true
  validates :status, inclusion: { in: %w[pending running completed failed] }

  # A run is single-use: only a pending run starts, so a finished run is never re-run
  # (its results would mix with the new ones). Create a new run instead.
  aasm column: :status, whiny_persistence: true do
    state :pending, initial: true
    state :running
    state :completed
    state :failed

    event :start do
      transitions from: :pending, to: :running, after: :record_start
    end

    # complete!(metrics)
    event :complete do
      transitions from: :running, to: :completed, after: :record_completion
    end

    # fail!(error), an exception or a message
    event :fail do
      transitions from: %i[pending running], to: :failed, after: :record_failure
    end
  end

  scope :for_model, ->(model) { where(model: model) }
  scope :for_provider, ->(provider) { where(provider: provider) }

  # Calculate duration in seconds
  def duration_seconds
    return nil unless started_at && completed_at
    (completed_at - started_at).to_i
  end

  # Get accuracy from metrics or calculate
  def accuracy
    metrics.dig("accuracy") || calculate_accuracy
  end

  # Summary for display
  def summary
    {
      id: id,
      name: name,
      dataset: dataset.name,
      model: model,
      provider: provider,
      status: status,
      accuracy: accuracy,
      total_cost: total_cost&.to_f,
      duration: duration_seconds,
      samples_processed: results.count,
      samples_correct: results.where(correct: true).count,
      created_at: created_at
    }
  end

  # Compare this run to another
  def compare_to(other_run)
    {
      accuracy_diff: (accuracy || 0) - (other_run.accuracy || 0),
      cost_diff: (total_cost || 0) - (other_run.total_cost || 0),
      this_model: model,
      other_model: other_run.model
    }
  end

  private
    def record_start
      self.started_at = Time.current
    end

    def record_completion(calculated_metrics)
      self.completed_at = Time.current
      self.metrics = calculated_metrics
      self.total_prompt_tokens = results.sum(:prompt_tokens)
      self.total_completion_tokens = results.sum(:completion_tokens)
      self.total_cost = results.sum(:cost)
    end

    def record_failure(error = "Run did not finish")
      self.completed_at = Time.current
      self.error_message = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    end

    def calculate_accuracy
      return 0.0 if results.empty?
      (results.where(correct: true).count.to_f / results.count * 100).round(2)
    end
end
