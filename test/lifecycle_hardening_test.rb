require_relative "test_helper"
require "active_job"
require "logister/active_job_reporter"
require "json"

class HardeningJob < ActiveJob::Base
  class_attribute :on_perform
  self.logger = Logger.new(StringIO.new)

  def perform(*arguments)
    self.class.on_perform.call(*arguments)
  end
end

class LifecycleHardeningTest < Minitest::Test
  def setup
    super
    Logister::ActiveJobReporter.install!
    @bodies = []
    bodies = @bodies
    Logister.reporter.instance_variable_get(:@client).define_singleton_method(:send_request) do |event|
      bodies << JSON.parse(event.json).fetch("event")
      true
    end
  end

  def teardown
    HardeningJob.on_perform = nil
    super
  end

  def test_job_arguments_and_user_are_redacted_and_scoped_to_the_job
    error = RuntimeError.new("job failed")
    HardeningJob.on_perform = lambda do |*|
      Logister.set_user(id: 9)
      raise error
    end

    raised = assert_raises(RuntimeError) do
      HardeningJob.perform_now({ "password" => "hunter2", "order_id" => 5 }, "Bearer abc123")
    end
    assert_same error, raised

    context = @bodies.last.fetch("context")
    assert_equal [{ "password" => "[REDACTED]", "order_id" => 5 }, "Bearer [REDACTED]"], context.dig("job", "arguments")
    assert_equal({ "id" => 9 }, context["user"])
    assert_nil Logister::ContextStore.user
  end

  def test_job_context_failure_never_replaces_the_job_exception
    Logister::ActiveJobReporter.singleton_class.alias_method :__original_build, :build_job_error_context
    Logister::ActiveJobReporter.define_singleton_method(:build_job_error_context) { |*, **| raise NoMethodError, "broken" }
    error = ArgumentError.new("job failed")
    HardeningJob.on_perform = ->(*) { raise error }

    assert_same error, assert_raises(ArgumentError) { HardeningJob.perform_now }
  ensure
    Logister::ActiveJobReporter.singleton_class.remove_method :build_job_error_context
    Logister::ActiveJobReporter.singleton_class.alias_method :build_job_error_context, :__original_build
    Logister::ActiveJobReporter.singleton_class.remove_method :__original_build
  end

  def test_span_attributes_and_log_fields_are_redacted
    Logister.report_span(name: "db", duration_ms: 1, context: { "db.statement_secret" => "s", attributes: { auth_token: "t", rows: 2 } })
    Logister.report_log(message: "login Bearer abc", context: { fields: { password: "p", user_id: 3 } })

    span, log = @bodies.last(2)
    assert_equal "[REDACTED]", span.dig("context", "db.statement_secret")
    assert_equal({ "auth_token" => "[REDACTED]", "rows" => 2 }, span.dig("context", "attributes"))
    assert_equal span.fetch("trace_id"), span.dig("context", "trace_id")
    assert_equal "login Bearer [REDACTED]", log.fetch("message")
    assert_equal({ "password" => "[REDACTED]", "user_id" => 3 }, log.dig("context", "fields"))
  end

  def test_breadcrumbs_are_redacted
    Logister.add_breadcrumb(category: "http", message: "GET /cb?code=1&token=abc", data: { api_key: "k", status: 200 })
    Logister.report_error(RuntimeError.new("boom"))

    breadcrumb = @bodies.last.dig("context", "breadcrumbs", 0)
    assert_equal "GET /cb?code=1&token=[REDACTED]", breadcrumb.fetch("message")
    assert_equal({ "api_key" => "[REDACTED]", "status" => 200 }, breadcrumb.fetch("data"))
  end

  def test_sql_breadcrumbs_are_off_by_default_and_strip_literals_when_enabled
    refute Logister::Configuration.new.capture_sql_breadcrumbs
    payload = { name: "User Load", sql: "SELECT * FROM users WHERE reset_token = 'abc' AND id = 42" }
    started = Time.now
    finished = started + 0.1

    Logister::RequestSubscriber.send(:handle_sql_breadcrumb, started, finished, payload)
    assert_empty Logister::ContextStore.breadcrumbs

    Logister.configuration.capture_sql_breadcrumbs = true
    Logister::RequestSubscriber.send(:handle_sql_breadcrumb, started, finished, payload)
    assert_equal "SELECT * FROM users WHERE reset_token = ? AND id = ?", Logister::ContextStore.breadcrumbs.last.dig(:data, :sql)
  end

  def test_db_metrics_strip_sql_literals
    Logister.configuration.capture_db_metrics = true
    started = Time.now
    Logister::SqlSubscriber.send(:handle_sql_event, started, started + 0.01, { name: "User Load", sql: "SELECT 1 WHERE email = 'a@b.c'" })

    assert_equal "SELECT ? WHERE email = ?", @bodies.last.dig("context", "sql")
  end

  def test_configure_shuts_down_the_previous_reporter_and_registers_one_exit_hook
    previous = Logister.reporter
    shutdowns = 0
    previous.define_singleton_method(:shutdown) { shutdowns += 1 }
    exit_hooks = 0
    Kernel.module_eval do
      alias_method :__logister_original_at_exit, :at_exit
      remove_method :at_exit
      define_method(:at_exit) { |&_block| exit_hooks += 1 }
    end
    Logister.instance_variable_set(:@shutdown_hook_registered, nil)

    3.times { Logister.configure { |config| config.service = "reconfigured" } }
    Logister.reporter

    assert_equal 1, shutdowns
    assert_equal 1, exit_hooks
    refute_same previous, Logister.reporter
  ensure
    Kernel.module_eval do
      remove_method :at_exit
      alias_method :at_exit, :__logister_original_at_exit
      remove_method :__logister_original_at_exit
    end
    Logister.instance_variable_set(:@shutdown_hook_registered, true)
  end

  def test_public_entry_points_never_raise_into_the_host
    Logister.reporter.instance_variable_get(:@client).define_singleton_method(:publish) { |_payload| raise IOError, "boom" }
    refute Logister.report_error(RuntimeError.new("x"))
    refute Logister.report_error(RuntimeError.new("x"), context: nil)
    refute Logister.report_log(message: "x", context: "not a hash")
    refute Logister.report_metric(message: "x")

    Logister.configure { |config| config.endpoint = "http://[invalid" }
    refute Logister.report_error(RuntimeError.new("x"))
    refute Logister.record_deployment
    assert_nil Logister.set_user(id: 1)
    assert_equal({}, Logister.delivery_stats)
    refute Logister.flush
    refute Logister.shutdown
  end
end
