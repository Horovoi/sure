# Enrichable models can have 1+ of their fields enriched by various
# external sources (i.e. Plaid) or internal sources (i.e. Rules)
#
# This module defines how models should, lock, unlock, and edit attributes
# based on the source of the edit.  User edits always take highest precedence.
#
# For example:
#
# If a Rule tells us to set the category to "Groceries", but the user later overrides
# a transaction with a category of "Food", we should not override the category again.
#
# Lock format: locked_attributes is { attr => { "source" => ..., "locked_at" => ... } }.
# The source says who locked it: "user" (an edit by the user) or "ai" (an AI
# enrichment). Older rows store a bare timestamp; those count as "user".
# A forced enrichment (a rule the user applies by hand) may replace a lock
# that is not a user lock, and never a user lock.
#
# A soft lock ("bayes", the local classifier's guess) records who set the value
# but blocks nothing: any later enrichment may replace it, forced or not, and a
# user edit replaces it with a user lock.
#
module Enrichable
  extend ActiveSupport::Concern

  InvalidAttributeError = Class.new(StandardError)

  USER_LOCK_SOURCE = "user".freeze
  SOFT_LOCK_SOURCES = %w[bayes].freeze

  included do
    scope :enrichable, ->(attrs, force: false) {
      where(Enrichable.unlocked_condition(table_name, attrs, force: force))
    }
  end

  # SQL condition: none of attrs is locked in table's locked_attributes.
  # With force, only user locks (including legacy timestamp locks) count.
  # Soft locks never count.
  def self.unlocked_condition(table, attrs, force: false)
    connection = ActiveRecord::Base.connection
    column = "#{connection.quote_table_name(table)}.locked_attributes"
    user = connection.quote(USER_LOCK_SOURCE)
    soft = SOFT_LOCK_SOURCES.map { |source| connection.quote(source) }.join(", ")

    conditions = Array(attrs).map do |attr|
      key = connection.quote(attr.to_s)
      source = "COALESCE(#{column} -> #{key} ->> 'source', #{user})"
      if force
        "NOT (#{column} ? #{key} AND #{source} = #{user})"
      else
        "NOT (#{column} ? #{key} AND #{source} NOT IN (#{soft}))"
      end
    end

    Arel.sql(conditions.join(" AND "))
  end

  # Convenience method for a single attribute
  def enrich_attribute(attr, value, source:, metadata: {}, force: false)
    enrich_attributes({ attr => value }, source:, metadata:, force:)
  end

  # Enriches and logs all attributes that:
  # - Are not locked
  # - Are not ignored
  # - Have changed value from the last saved value
  # Returns true if any attributes were actually changed, false otherwise
  # With force, attributes locked by a non-user source are enriched too, and
  # their lock is released (the new value no longer comes from that source).
  def enrich_attributes(attrs, source:, metadata: {}, force: false)
    # Track current values before modification for virtual attributes (like tag_ids)
    current_values = {}
    enrichable_attrs = Array(attrs).reject do |attr_key, attr_value|
      blocked_by_lock = locked?(attr_key) && !soft_locked?(attr_key) && !(force && !user_locked?(attr_key))

      if blocked_by_lock || ignored_enrichable_attributes.include?(attr_key)
        true
      else
        # For virtual attributes (like tag_ids), use the getter method
        # For regular attributes, use self[attr_key]
        current_value = if respond_to?(attr_key.to_sym)
          send(attr_key.to_sym)
        else
          self[attr_key.to_s]
        end

        # Normalize arrays for comparison (sort them)
        if current_value.is_a?(Array) && attr_value.is_a?(Array)
          current_values[attr_key] = current_value
          current_value.sort == attr_value.sort
        else
          current_values[attr_key] = current_value
          current_value == attr_value
        end
      end
    end

    return false if enrichable_attrs.empty?

    # A new record's first save is not an enrichment, so it is not logged. Read before
    # the save, which clears new_record?.
    was_new = new_record?
    was_modified = false
    refused = false
    # A savepoint, so a refused save also undoes the join rows that virtual attributes
    # (like tag_ids) write on assignment, even inside a caller's transaction.
    ActiveRecord::Base.transaction(requires_new: true) do
      # Attributes this enrichment may overwrite release their (non-user) locks
      released = enrichable_attrs.map { |attr, _| attr.to_s }.select { |attr| locked?(attr) }
      self.locked_attributes = locked_attributes.except(*released) if released.any?

      enrichable_attrs.each do |attr, value|
        self.send("#{attr}=", value)
      end

      # A new record is only being filled in (callers such as the Plaid processor set
      # the rest and save it themselves), so its values stay assigned.
      unless save || new_record?
        Rails.logger.warn("#{self.class.name} #{id} not enriched from #{source}: #{errors.full_messages.to_sentence}")
        restore_attributes
        refused = true
        raise ActiveRecord::Rollback
      end

      # Provenance is logged only for values the record accepted
      unless was_new
        enrichable_attrs.each do |attr, value|
          log_enrichment(attribute_name: attr, attribute_value: value, source: source, metadata: metadata)
        end
      end

      # For virtual attributes (like tag_ids), previous_changes won't track them
      # So we need to check if the value actually changed by comparing before/after
      if previous_changes.any?
        was_modified = true
      else
        # Check if any virtual attributes changed by comparing current value with what we set
        enrichable_attrs.each do |attr, new_value|
          # Get the current value after save (for virtual attributes, this reflects the change)
          current_value = if respond_to?(attr.to_sym)
            send(attr.to_sym)
          else
            self[attr.to_s]
          end

          old_value = current_values[attr]
          if old_value.is_a?(Array) && new_value.is_a?(Array) && current_value.is_a?(Array)
            was_modified = true if old_value.sort != current_value.sort
          elsif old_value != current_value
            was_modified = true
          end
          break if was_modified
        end
      end
    end

    reset_collection_caches(enrichable_attrs.map(&:first)) if refused

    # Return whether any attributes were actually saved
    was_modified
  end

  def locked?(attr)
    locked_attributes[attr.to_s].present?
  end

  def enrichable?(attr)
    !locked?(attr) || soft_locked?(attr)
  end

  # Who locked attr: "user", "ai", ... or nil when it is not locked.
  def lock_source(attr)
    value = locked_attributes[attr.to_s]
    return nil if value.blank?

    value.is_a?(Hash) ? (value["source"].presence || USER_LOCK_SOURCE) : USER_LOCK_SOURCE
  end

  def user_locked?(attr)
    lock_source(attr) == USER_LOCK_SOURCE
  end

  def soft_locked?(attr)
    lock_source(attr).in?(SOFT_LOCK_SOURCES)
  end

  def lock_attr!(attr, source: USER_LOCK_SOURCE)
    update!(locked_attributes: locked_attributes.merge(attr.to_s => { "source" => source.to_s, "locked_at" => Time.current.iso8601 }))
  end

  def unlock_attr!(attr)
    update!(locked_attributes: locked_attributes.except(attr.to_s))
  end

  def lock_saved_attributes!
    saved_changes.keys.reject { |attr| ignored_enrichable_attributes.include?(attr) }.each do |attr|
      lock_attr!(attr)
    end
  end

  private
    # The rollback removes the join rows a collection setter such as tag_ids= inserted,
    # but not the records it loaded into the association. Resetting makes the next read
    # go to the database, so the instance stops reporting the refused ids as current
    # and a retry is not skipped as unchanged.
    def reset_collection_caches(attr_names)
      attr_names.each do |attr_name|
        reflection = self.class.reflect_on_all_associations.find do |r|
          r.collection? && "#{r.name.to_s.singularize}_ids" == attr_name.to_s
        end
        next unless reflection

        association(reflection.name).reset
        association(reflection.through_reflection.name).reset if reflection.through_reflection?
      end
    end

    # Upsert against the unique (enrichable, source, attribute) index, so a
    # rule and an AI job writing the same record at once cannot collide.
    def log_enrichment(attribute_name:, attribute_value:, source:, metadata: {})
      now = Time.current
      DataEnrichment.upsert(
        {
          enrichable_type: self.class.polymorphic_name,
          enrichable_id: id,
          attribute_name: attribute_name.to_s,
          source: source.to_s,
          value: attribute_value,
          metadata: metadata,
          created_at: now,
          updated_at: now
        },
        unique_by: %i[enrichable_id enrichable_type source attribute_name],
        update_only: %i[value metadata]
      )
    end

    def ignored_enrichable_attributes
      %w[id updated_at created_at]
    end
end
