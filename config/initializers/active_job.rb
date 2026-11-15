# A job enqueued inside a database transaction waits for the commit, and is dropped when
# the transaction rolls back. The app relies on this: Syncable#sync_later creates the Sync
# row and enqueues its SyncJob in one transaction, so a worker that picked the job up
# before the commit would not find the row, and discard_on would drop the job silently.
#
# Rails 7.2 did this for Sidekiq by default. Rails 8 enqueues at once unless the job class
# says otherwise, and has no global setting, so it is set on the base class of every job
# (the app's own and the framework's mail and Active Storage jobs).
ActiveSupport.on_load(:active_job) do
  self.enqueue_after_transaction_commit = true
end
