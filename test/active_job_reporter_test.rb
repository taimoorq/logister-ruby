require_relative "test_helper"
require "active_job"
require "logister/active_job_reporter"
require "rack/mock"

class ScopeJob < ActiveJob::Base
  class_attribute :on_perform
  self.logger = Logger.new(StringIO.new)

  def perform(label)
    self.class.on_perform.call(label)
  end
end

class ActiveJobReporterTest < Minitest::Test
  def setup
    super
    Logister::ActiveJobReporter.install!
    @events = []
    events = @events
    Logister.reporter.instance_variable_get(:@client).define_singleton_method(:publish) do |payload|
      events << payload
      true
    end
  end

  def teardown
    ScopeJob.on_perform = nil
    super
  end

  def test_perform_now_preserves_request_scope_with_reporting_disabled
    Logister.configuration.enabled = false
    assert_inline_request { ScopeJob.perform_now("inline") }
    assert_empty @events
  end

  def test_inline_queue_adapter_preserves_request_scope
    previous_adapter = ScopeJob.queue_adapter
    ScopeJob.queue_adapter = :inline
    assert_inline_request { ScopeJob.perform_later("inline") }
  ensure
    ScopeJob.queue_adapter = previous_adapter
  end

  def test_nested_jobs_restore_each_enclosing_scope
    assert_nested_request(fail_child: false)
  end

  def test_rescued_nested_job_failure_restores_each_enclosing_scope
    assert_nested_request(fail_child: true)
    context = @events.fetch(0).fetch(:context)
    assert_equal "ScopeJob", context.dig(:job, :jobClass)
    assert_equal ["inner"], context.fetch(:dependencyCalls).map { |entry| entry[:name] }
    assert_equal ["Starting ScopeJob", "inner"], context.fetch(:breadcrumbs).map { |entry| entry[:message] }
  end

  def test_rescued_inline_failure_keeps_redirect_and_request_telemetry
    failure = RuntimeError.new("job failed")
    ScopeJob.on_perform = ->(_) { add_scope_data("job"); raise failure }
    middleware = Logister::Middleware.new(lambda do |_env|
      add_scope_data("request")
      before = scope_snapshot
      assert_same failure, assert_raises(RuntimeError) { ScopeJob.perform_now("inline") }
      assert_scope before
      Logister.report_error(RuntimeError.new("handled request failure"))
      [302, { "location" => "/done" }, []]
    end)

    status, headers, = middleware.call(request_env)

    assert_equal 302, status
    assert_equal "/done", headers["location"]
    assert_equal "request-123", headers["x-request-id"]
    assert_equal 2, @events.size
    context = @events.last.fetch(:context)
    assert_equal "request-123", context[:request_id]
    assert_equal ["request"], context.fetch(:breadcrumbs).map { |entry| entry[:message] }
    assert_equal ["request"], context.fetch(:dependencyCalls).map { |entry| entry[:name] }
    assert_empty_scope
  end

  def test_unhandled_inline_failure_is_reported_in_job_then_request_scope_and_propagates
    failure = RuntimeError.new("job failed")
    ScopeJob.on_perform = ->(_) { add_scope_data("job"); raise failure }
    middleware = Logister::Middleware.new(lambda do |_env|
      add_scope_data("request")
      ScopeJob.perform_now("inline")
    end)

    assert_same failure, assert_raises(RuntimeError) { middleware.call(request_env) }

    assert_equal 2, @events.size
    job_context, request_context = @events.map { |event| event.fetch(:context) }
    assert_equal "ScopeJob", job_context.dig(:job, :jobClass)
    assert_nil job_context[:request_id]
    assert_equal ["job"], job_context.fetch(:dependencyCalls).map { |entry| entry[:name] }
    assert_equal "request-123", request_context[:request_id]
    assert_equal ["request"], request_context.fetch(:breadcrumbs).map { |entry| entry[:message] }
    assert_equal ["request"], request_context.fetch(:dependencyCalls).map { |entry| entry[:name] }
    assert_empty_scope
  end

  def test_non_standard_error_restores_the_enclosing_scope
    failure = Class.new(Exception).new("interrupted")
    Logister::ContextStore.trace_context = Logister::TraceContext.new
    add_scope_data("parent")
    before = scope_snapshot
    ScopeJob.on_perform = ->(_) { add_scope_data("job"); raise failure }

    assert_same failure, assert_raises(failure.class) { ScopeJob.perform_now("inline") }

    assert_scope before
    assert_empty @events
  end

  def test_serialized_standalone_jobs_start_isolated_and_clean_up_on_success_and_failure
    failure = RuntimeError.new("worker job failed")
    ScopeJob.on_perform = lambda do |label|
      assert_job_scope
      Logister::ContextStore.trace_context = Logister::TraceContext.new
      add_scope_data(label)
      raise failure if label == "failure"
    end

    Thread.new do
      %w[first failure last].each do |label|
        serialized = ScopeJob.new(label).serialize
        if label == "failure"
          assert_same failure, assert_raises(RuntimeError) { ActiveJob::Base.execute(serialized) }
        else
          ActiveJob::Base.execute(serialized)
        end
        assert_empty_scope
      end
    end.value
    assert_empty_scope
  end

  private

  def assert_inline_request
    ScopeJob.on_perform = lambda do |_label|
      assert_job_scope
      Logister::ContextStore.trace_context = Logister::TraceContext.new
      add_scope_data("job")
    end
    middleware = Logister::Middleware.new(lambda do |env|
      assert_same env["logister.trace_context"], Logister.current_trace_context
      add_scope_data("request")
      before = scope_snapshot
      yield
      assert_scope before
      [202, { "content-type" => "text/plain" }, ["accepted"]]
    end)

    status, headers, body = middleware.call(request_env)

    assert_equal 202, status
    assert_equal "request-123", headers["x-request-id"]
    assert_equal ["accepted"], body
    assert_empty_scope
  end

  def assert_nested_request(fail_child:)
    failure = RuntimeError.new("nested job failed")
    ScopeJob.on_perform = lambda do |label|
      assert_job_scope
      Logister::ContextStore.trace_context = Logister::TraceContext.new
      add_scope_data(label)
      if label == "outer"
        before = scope_snapshot
        if fail_child
          assert_same failure, assert_raises(RuntimeError) { ScopeJob.perform_now("inner") }
        else
          assert_equal :performed, ScopeJob.perform_now("inner")
        end
        assert_scope before
      elsif fail_child
        raise failure
      end
      :performed
    end
    middleware = Logister::Middleware.new(lambda do |_env|
      add_scope_data("request")
      before = scope_snapshot
      assert_equal :performed, ScopeJob.perform_now("outer")
      assert_scope before
      [202, {}, []]
    end)

    status, headers, = middleware.call(request_env)

    assert_equal 202, status
    assert_equal "request-123", headers["x-request-id"]
    assert_equal(fail_child ? 1 : 0, @events.size)
    assert_empty_scope
  end

  def request_env
    Rack::MockRequest.env_for("https://example.com/jobs", "HTTP_X_REQUEST_ID" => "request-123")
  end

  def add_scope_data(label)
    Logister.add_breadcrumb(category: "test", message: label)
    Logister.add_dependency(name: label, duration_ms: 2)
  end

  def scope_snapshot
    [Logister.current_trace_context, Logister::ContextStore.breadcrumbs, Logister::ContextStore.dependencies]
  end

  def assert_scope(expected)
    assert_same expected[0], Logister.current_trace_context
    assert_equal expected[1], Logister::ContextStore.breadcrumbs
    assert_equal expected[2], Logister::ContextStore.dependencies
  end

  def assert_job_scope
    assert_nil Logister.current_trace_context
    assert_equal ["Starting ScopeJob"], Logister::ContextStore.breadcrumbs.map { |entry| entry[:message] }
    assert_empty Logister::ContextStore.dependencies
  end

  def assert_empty_scope
    assert_nil Logister.current_trace_context
    assert_empty Logister::ContextStore.breadcrumbs
    assert_empty Logister::ContextStore.dependencies
  end
end
