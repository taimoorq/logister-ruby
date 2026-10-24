require 'active_support/core_ext/object/blank'
require_relative 'logister/version'
require_relative 'logister/configuration'
require_relative 'logister/redaction'
require_relative 'logister/event_sanitizer'
require_relative 'logister/reporting_scope'
require_relative 'logister/client'
require_relative 'logister/reporter'
require_relative 'logister/context_helpers'
require_relative 'logister/context_store'
require_relative 'logister/trace_context'
require_relative 'logister/middleware'
require_relative 'logister/sql_subscriber'
require_relative 'logister/request_subscriber'

module Logister
  class << self
    def current_trace_context
      ContextStore.trace_context
    end

    # The returned child is the handle for this outbound attempt. Supply its
    # to_h as context when reporting an error after the request scope has ended.
    def outbound_trace_context
      (current_trace_context || TraceContext.new).child
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # Reconfiguring replaces the reporter. The previous client drains what it
    # already queued and stops, so repeated calls never leave idle workers.
    def configure
      yield(configuration)
      previous = @reporter
      @reporter = nil
      safely(nil) { previous&.shutdown }
      register_shutdown_hook
    end

    def reporter
      register_shutdown_hook
      @reporter ||= Reporter.new(configuration)
    end

    def suppress_reporting(&block)
      ReportingScope.suppress(&block)
    end

    def reporting_suppressed?
      ReportingScope.suppressed?
    end

    def report_error(exception, **kwargs)
      safely { reporter.report_error(exception, **kwargs) }
    end

    def report_metric(**kwargs)
      safely { reporter.report_metric(**kwargs) }
    end

    def report_transaction(**kwargs)
      safely { reporter.report_transaction(**kwargs) }
    end

    def report_span(**kwargs)
      safely { reporter.report_span(**kwargs) }
    end

    def report_log(**kwargs)
      safely { reporter.report_log(**kwargs) }
    end

    def report_check_in(**kwargs)
      safely { reporter.report_check_in(**kwargs) }
    end

    def record_deployment(**kwargs)
      safely { reporter.record_deployment(**kwargs) }
    end

    # Attaches user identity to errors reported in the current request or job.
    # The Rack middleware and Active Job integration clear it when the request
    # or job ends; call clear_user yourself in other long-lived threads.
    def set_user(**kwargs)
      safely(nil) { reporter.set_user(**kwargs) }
    end

    def clear_user
      safely(nil) { reporter.clear_user }
    end

    def flush(timeout: 2)
      safely { reporter.flush(timeout: timeout) }
    end

    def delivery_stats
      safely({}) { reporter.delivery_stats }
    end

    def shutdown
      safely { reporter.shutdown }
    end

    def add_breadcrumb(category:, message:, data: {}, level: "info")
      safely(nil) do
        ContextStore.add_manual_breadcrumb(
          category: category,
          message: message,
          data: data,
          level: level
        )
      end
    end

    def add_dependency(name:, host: nil, method: nil, status: nil, duration_ms: nil, kind: nil, data: {})
      safely(nil) do
        ContextStore.add_manual_dependency(
          name: name,
          host: host,
          method: method,
          status: status,
          duration_ms: duration_ms,
          kind: kind,
          data: data
        )
      end
    end

    # Telemetry must never raise into the host application.
    def log_internal_error(label, error)
      configuration.logger&.warn("logister #{label} failed: #{error.class}")
    rescue StandardError
      nil
    end

    private

    def safely(fallback = false)
      yield
    rescue StandardError => e
      log_internal_error('call', e)
      fallback
    end

    def register_shutdown_hook
      return if @shutdown_hook_registered

      @shutdown_hook_registered = true
      at_exit { safely(nil) { @reporter&.shutdown } }
    end
  end
end

require_relative 'logister/railtie' if defined?(Rails::Railtie)
