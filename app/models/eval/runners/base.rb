class Eval::Runners::Base
  attr_reader :eval_run

  def initialize(eval_run)
    @eval_run = eval_run
  end

  AlreadyRunError = Class.new(StandardError)

  def run
    unless eval_run.may_start?
      raise AlreadyRunError, "Eval run #{eval_run.id} is #{eval_run.status}; create a new run to evaluate again"
    end

    eval_run.start!

    begin
      process_samples
      metrics = calculate_metrics
      eval_run.complete!(metrics)
    rescue => e
      eval_run.fail!(e)
      raise
    ensure
      # Interrupt (Ctrl-C) and other non-StandardError exceptions skip the rescue above
      eval_run.fail!($! || "Run ended before completing") if eval_run.running?
    end

    eval_run
  end

  protected

    def process_samples
      raise NotImplementedError, "Subclasses must implement #process_samples"
    end

    def calculate_metrics
      raise NotImplementedError, "Subclasses must implement #calculate_metrics"
    end

    def samples
      eval_run.dataset.samples
    end

    def provider
      @provider ||= build_provider
    end

    def model
      eval_run.model
    end

  private

    def build_provider
      case eval_run.provider
      when "openai"
        build_openai_provider
      else
        raise "Unsupported provider: #{eval_run.provider}"
      end
    end

    def build_openai_provider
      access_token = eval_run.provider_config["access_token"].presence ||
                     ENV["OPENAI_ACCESS_TOKEN"].presence ||
                     Setting.openai_access_token

      raise "OpenAI access token not configured" unless access_token.present?

      uri_base = eval_run.provider_config["uri_base"].presence ||
                 ENV["OPENAI_URI_BASE"].presence ||
                 Setting.openai_uri_base

      Provider::Openai.new(access_token, uri_base: uri_base, model: model)
    end

    def record_result(sample:, actual_output:, correct:, **attributes)
      eval_run.results.create!(
        sample: sample,
        actual_output: actual_output,
        correct: correct,
        **attributes
      )
    end

    def log_progress(message)
      Rails.logger.info("[Eval::Runner] #{message}")
    end
end
