# frozen_string_literal: true

module Logister
  class SqlSubscriber
    IGNORED_SQL_NAMES = %w[SCHEMA TRANSACTION].freeze

    # Frozen constants for values emitted on every captured query.
    MESSAGE       = 'db.query'
    LEVEL_WARN    = 'warn'
    LEVEL_INFO    = 'info'
    TAGS          = { category: 'database' }.freeze

    # Pre-compute the fingerprint for the fixed message string so we pay the
    # SHA256 cost exactly once instead of on every captured SQL query.
    require 'digest'
    SQL_FINGERPRINT = Digest::SHA256.hexdigest(MESSAGE)[0, 32].freeze

    class << self
      def install!
        return if @installed

        ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, started, finished, _id, payload|
          handle_sql_event(started, finished, payload)
        end

        @installed = true
      end

      private

      def handle_sql_event(started, finished, payload)
        config = Logister.configuration

        # Short-circuit as cheaply as possible when metrics are disabled so
        # that *every* SQL query in the app pays minimal overhead.
        return unless config.capture_db_metrics
        return if payload[:cached]

        # Evaluate name once — it's used in two places below.
        sql_name = payload[:name].to_s
        return if IGNORED_SQL_NAMES.include?(sql_name)

        duration_ms = (finished - started) * 1000.0
        return if duration_ms < config.db_metric_min_duration_ms.to_f
        return if sampled_out?(config.db_metric_sample_rate)

        Logister.report_metric(
          message:     MESSAGE,
          level:       duration_ms >= 500 ? LEVEL_WARN : LEVEL_INFO,
          fingerprint: SQL_FINGERPRINT,
          context: {
            duration_ms: duration_ms.round(2),
            name:        sql_name,
            sql:         payload[:sql].to_s,
            cached:      false,
            binds_count: (payload[:binds] || []).size
          },
          tags: TAGS
        )
      rescue StandardError => e
        config.logger.warn("logister sql subscriber failed: #{e.class} #{e.message}")
      end

      def sampled_out?(sample_rate)
        rate = sample_rate.to_f
        return true if rate <= 0.0
        return false if rate >= 1.0

        rand > rate
      end
    end
  end
end
