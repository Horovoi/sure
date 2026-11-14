# Data fix: impersonation sessions used to stay in_progress forever, and
# browser sessions kept pointing at completed or rejected ones. Approved
# sessions now expire after ImpersonationSession::IN_PROGRESS_TTL (2 hours).
# Idempotent: re-running changes nothing.
class CompleteStaleImpersonationSessions < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE impersonation_sessions
      SET status = 'complete', updated_at = NOW()
      WHERE status = 'in_progress' AND updated_at < NOW() - INTERVAL '2 hours'
    SQL

    execute <<~SQL
      UPDATE sessions
      SET active_impersonator_session_id = NULL
      WHERE active_impersonator_session_id IN (
        SELECT id FROM impersonation_sessions WHERE status IN ('complete', 'rejected')
      )
    SQL
  end

  def down
    # Data fix only; nothing to undo
  end
end
