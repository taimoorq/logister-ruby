require_relative "test_helper"

class ReportingScopeTest < Minitest::Test
  REPORT_METHODS = {
    error: -> { Logister.report_error(StandardError.new("failure")) },
    metric: -> { Logister.report_metric(message: "queue.depth", value: 1, unit: "job") },
    transaction: -> { Logister.report_transaction(name: "GET /", duration_ms: 12) },
    span: -> { Logister.report_span(name: "GET /", duration_ms: 12) },
    log: -> { Logister.report_log(message: "worker started") },
    check_in: -> { Logister.report_check_in(slug: "worker") },
    deployment: -> { Logister.record_deployment(release: "abc123") }
  }.freeze

  def test_suppresses_every_reporting_entry_point
    calls = []
    Logister.configure do |config|
      config.before_notify = lambda do |payload|
        calls << payload
        payload
      end
    end

    results = Logister.suppress_reporting do
      REPORT_METHODS.transform_values(&:call)
    end

    assert results.values.none?
    assert_empty calls
    refute Logister.reporting_suppressed?
  end

  def test_nested_scopes_restore_the_previous_state
    observed = Logister.suppress_reporting do
      outer = Logister.reporting_suppressed?
      inner = Logister.suppress_reporting { Logister.reporting_suppressed? }
      [outer, inner, Logister.reporting_suppressed?]
    end

    assert_equal [true, true, true], observed
    refute Logister.reporting_suppressed?
  end

  def test_restores_state_after_an_exception
    assert_raises(RuntimeError) do
      Logister.suppress_reporting { raise "boom" }
    end

    refute Logister.reporting_suppressed?
  end
end
