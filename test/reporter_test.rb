require_relative "test_helper"

class ReporterTest < Minitest::Test
  def test_report_error_enriches_manual_errors_with_shared_context
    captured_payload = nil
    Logister.configure do |config|
      config.before_notify = lambda do |payload|
        captured_payload = payload
        false
      end
    end

    Logister.add_breadcrumb(
      category: "checkout",
      message: "Starting payment",
      data: { order_id: 123 }
    )
    Logister.add_dependency(
      name: "stripe.charge",
      host: "api.stripe.com",
      method: "POST",
      status: 503,
      duration_ms: 184.7,
      kind: "http"
    )

    Logister.report_error(nested_error)

    refute_nil captured_payload
    context = captured_payload.fetch(:context)
    assert_equal RUBY_VERSION, context.fetch(:runtime).fetch(:rubyVersion)
    assert_equal "logister-ruby-test", context.fetch(:deployment).fetch(:service)
    assert_equal "Starting payment", context.fetch(:breadcrumbs).first.fetch(:message)
    assert_equal "stripe.charge", context.fetch(:dependencyCalls).first.fetch(:name)
    assert_equal "RuntimeError", context.fetch(:exception).fetch(:class)
    assert_equal "outer failure", context.fetch(:exception).fetch(:message)
    assert_equal "ArgumentError", context.dig(:exception, :cause, :class)
    assert_equal "inner failure", context.dig(:exception, :cause, :message)
  end

  def test_report_metric_accepts_value_and_unit_options
    captured_payload = nil
    Logister.configure do |config|
      config.before_notify = lambda do |payload|
        captured_payload = payload
        false
      end
    end

    Logister.report_metric(message: "queue.depth", value: 12, unit: "jobs")

    refute_nil captured_payload
    context = captured_payload.fetch(:context)
    assert_equal "metric", captured_payload.fetch(:event_type)
    assert_equal "queue.depth", captured_payload.fetch(:message)
    assert_equal 12, context.fetch(:metric).fetch(:value)
    assert_equal "jobs", context.fetch(:metric).fetch(:unit)
    assert_equal 12, context.fetch(:value)
    assert_equal "jobs", context.fetch(:unit)
  end

  def test_report_check_in_accepts_delivery_options
    captured_payload = nil
    checked_at = Time.utc(2026, 5, 21, 12, 0, 0)
    Logister.configure do |config|
      config.before_notify = lambda do |payload|
        captured_payload = payload
        false
      end
    end

    Logister.report_check_in(
      slug: "nightly-import",
      status: "ok",
      expected_interval_seconds: 600,
      duration_ms: 88.5,
      environment: "production",
      release: "app@1.2.3",
      occurred_at: checked_at,
      trace_id: "trace-123",
      request_id: "req-123"
    )

    refute_nil captured_payload
    context = captured_payload.fetch(:context)
    assert_equal "check_in", captured_payload.fetch(:event_type)
    assert_equal "2026-05-21T12:00:00Z", captured_payload.fetch(:occurred_at)
    assert_equal "nightly-import", context.fetch(:check_in_slug)
    assert_equal "ok", context.fetch(:check_in_status)
    assert_equal 600, context.fetch(:expected_interval_seconds)
    assert_equal 88.5, context.fetch(:duration_ms)
    assert_equal "production", context.fetch(:environment)
    assert_equal "app@1.2.3", context.fetch(:release)
    assert_equal "trace-123", context.fetch(:trace_id)
    assert_equal "req-123", context.fetch(:request_id)
  end

  private

  def nested_error
    begin
      raise ArgumentError, "inner failure"
    rescue ArgumentError => e
      raise RuntimeError, "outer failure"
    end
  rescue RuntimeError => e
    e
  end
end
