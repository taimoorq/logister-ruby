# frozen_string_literal: true

module Logister
  module ReportingScope
    STATE_KEY = :__logister_reporting_suppressed

    module_function

    def suppress
      previous = state
      self.state = true
      yield
    ensure
      self.state = previous
    end

    def suppressed?
      state == true
    end

    def state
      if defined?(ActiveSupport::IsolatedExecutionState)
        ActiveSupport::IsolatedExecutionState[STATE_KEY]
      else
        Thread.current[STATE_KEY]
      end
    end
    private_class_method :state

    def state=(value)
      if defined?(ActiveSupport::IsolatedExecutionState)
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = value
      else
        Thread.current[STATE_KEY] = value
      end
    end
    private_class_method :state=
  end
end
