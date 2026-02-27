# frozen_string_literal: true

require_relative 'logister/version'
require_relative 'logister/configuration'
require_relative 'logister/client'
require_relative 'logister/reporter'
require_relative 'logister/middleware'
require_relative 'logister/sql_subscriber'

module Logister
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      @reporter = nil
    end

    def reporter
      @reporter ||= Reporter.new(configuration)
    end

    def report_error(exception, **kwargs)
      reporter.report_error(exception, **kwargs)
    end

    def report_metric(**kwargs)
      reporter.report_metric(**kwargs)
    end

    def set_user(id: nil, email: nil, name: nil, **extra)
      reporter.set_user(id: id, email: email, name: name, **extra)
    end

    def clear_user
      reporter.clear_user
    end

    def flush(timeout: 2)
      reporter.flush(timeout: timeout)
    end

    def shutdown
      reporter.shutdown
    end
  end
end

require_relative 'logister/railtie' if defined?(Rails::Railtie)
