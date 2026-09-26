require "test_helper"
require "action_controller"
require "active_job"
require "logister/active_job_reporter"
require "rack/mock"

class CorrelationJob < ActiveJob::Base
  self.logger = Logger.new(StringIO.new)

  def perform
    Logister.add_breadcrumb(category: "job", message: "inline job")
    Logister.add_dependency(name: "inline dependency")
  end
end

class CorrelationController < ActionController::Base
  def show
    Logister.report_log(message: "request log")
    Logister.report_error(RuntimeError.new("handled request failure"))
    render plain: "ok"
  end

  def inline
    CorrelationJob.perform_now
    show
  end
end

class TraceContextTest < Minitest::Test
  HEADER = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

  def test_real_controller_notification_and_telemetry_share_one_request_context
    assert_controller_correlation("show")
  end

  def test_real_controller_notification_and_telemetry_keep_request_context_after_inline_job
    Logister::ActiveJobReporter.install!
    assert_controller_correlation("inline")
  end

  def assert_controller_correlation(action)
    Logister.configuration.capture_request_spans = true
    Logister::RequestSubscriber.install!
    events = []
    transport = Logister.reporter.instance_variable_get(:@client)
    transport.define_singleton_method(:publish) { |payload| events << payload; true }
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { get "/correlation", to: "correlation##{action}" }
    app = Logister::Middleware.new(routes)
    response = Rack::MockRequest.new(app).get("/correlation", "HTTP_TRACEPARENT" => HEADER, "HTTP_X_REQUEST_ID" => "request-1")
    assert_equal 200, response.status
    assert_equal "request-1", response.headers["x-request-id"]
    assert_nil Logister.current_trace_context
    assert_nil Logister::ContextStore.request_summary("request-1")
    assert_equal %w[error log span], events.map { |event| event[:event_type] }.sort
    contexts = events.map { |event| event[:context] }
    assert_equal ["4bf92f3577b34da6a3ce929d0e0e4736"], contexts.map { |context| context[:trace_id] }.uniq
    assert_equal 1, contexts.map { |context| context[:span_id] }.uniq.size
    assert_equal ["00f067aa0ba902b7"], contexts.map { |context| context[:parent_span_id] }.uniq
    assert_equal ["request-1"], contexts.map { |context| context[:request_id] }.uniq
    assert events.find { |event| event[:event_type] == "span" }[:duration_ms].positive?
  ensure
    Logister.configuration.capture_request_spans = false
  end

  def test_captured_mobile_wire_generates_real_rails_envelopes
    directory = ENV["LOGISTER_CORRELATION_FIXTURES"]
    return unless directory
    Logister.configuration.capture_request_spans = true
    Logister::RequestSubscriber.install!
    %w[ios android].each do |platform|
      fixture = JSON.parse(File.read(File.join(directory, "#{platform}.json")))
      events = []
      transport = Logister.reporter.instance_variable_get(:@client)
      transport.define_singleton_method(:publish) { |payload| events << {event: payload}; true }
      routes = ActionDispatch::Routing::RouteSet.new
      routes.draw { get "/correlation", to: "correlation#show" }
      headers = fixture.fetch("headers").to_h { |key, value| ["HTTP_#{key.upcase.tr('-', '_')}", value] }
      response = Rack::MockRequest.new(Logister::Middleware.new(routes)).get("/correlation", headers)
      assert_equal 200, response.status
      File.write(File.join(directory, "ruby-#{platform}.json"), JSON.pretty_generate({envelopes: events}))
    end
  ensure
    Logister.configuration.capture_request_spans = false
  end

  def test_strict_parsing_and_scope_isolation
    assert_nil Logister::TraceContext.parse("00-#{'0' * 32}-00f067aa0ba902b7-01")
    assert_nil Logister::TraceContext.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-#{'0' * 16}-01")
    assert_nil Logister::TraceContext.parse("garbage")
    trace = Logister::TraceContext.from_headers(traceparent: HEADER)
    child = trace.child
    assert_equal trace.trace_id, child.trace_id
    assert_equal trace.span_id, child.parent_span_id
    assert_empty child.headers_for("https://api.example.evil/path", allowed_origins: ["https://api.example"])
    assert_equal child.traceparent, child.headers_for("https://api.example:443/path", allowed_origins: ["https://api.example"])["traceparent"]
    fibers = 2.times.map do
      Fiber.new do
        Logister::ContextStore.trace_context = Logister::TraceContext.new
        own = Logister.current_trace_context
        Fiber.yield
        assert_same own, Logister.current_trace_context
        Logister::ContextStore.reset_request_scope!
      end
    end
    fibers.each(&:resume)
    fibers.each(&:resume)
    assert_nil Logister.current_trace_context
  end
end
