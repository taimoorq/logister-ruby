require_relative "test_helper"

class MiddlewareTest < Minitest::Test
  def test_middleware_reports_unhandled_exceptions_with_request_context
    middleware = Logister::Middleware.new(lambda { |_env| raise StandardError, "boom" })

    captured_exception = nil
    captured_context = nil
    logister_singleton = Logister.singleton_class
    original_method_name = :__logister_test_original_report_error

    logister_singleton.alias_method original_method_name, :report_error
    logister_singleton.remove_method :report_error
    logister_singleton.define_method(:report_error) do |exception, **kwargs|
      captured_exception = exception
      captured_context = kwargs[:context]
      true
    end

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/widgets",
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new,
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "example.com",
      "SERVER_NAME" => "example.com",
      "SERVER_PORT" => "443",
      "REMOTE_ADDR" => "127.0.0.1",
      "HTTP_USER_AGENT" => "Minitest",
      "action_dispatch.request_id" => "req-123",
      "action_dispatch.request.parameters" => { "controller" => "widgets", "action" => "show" },
      "action_dispatch.route_name" => :widget,
      "action_dispatch.route_uri_pattern" => "/widgets"
    }

    error = assert_raises(StandardError) { middleware.call(env) }
    assert_equal "boom", error.message

    refute_nil captured_exception
    refute_nil captured_context
    assert_equal "boom", captured_exception.message
    assert_equal "/widgets", captured_context[:path]
    assert_equal "GET", captured_context[:method]
    assert_equal "req-123", captured_context[:request_id]
    assert_equal 500, captured_context.dig(:response, :status)
    assert_equal "widgets#show", captured_context[:railsAction]
    assert_equal "/widgets", captured_context.dig(:route, :pathTemplate)
  ensure
    if logister_singleton.method_defined?(:report_error)
      logister_singleton.remove_method :report_error
    end
    if logister_singleton.method_defined?(original_method_name)
      logister_singleton.alias_method :report_error, original_method_name
      logister_singleton.remove_method original_method_name
    end
  end
end
