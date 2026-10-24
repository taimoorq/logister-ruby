require_relative "test_helper"
require "rack/mock"
require "open3"
require "rbconfig"

class MiddlewareHardeningTest < Minitest::Test
  def setup
    super
    @reports = []
    reports = @reports
    Logister.reporter.instance_variable_get(:@client).define_singleton_method(:publish) do |payload|
      reports << payload
      true
    end
  end

  def failing_env(url = "https://example.com/widgets", **headers)
    Rack::MockRequest.env_for(url, { "REMOTE_ADDR" => "198.51.100.23" }.merge(headers))
  end

  def call_failing(env, error = RuntimeError.new("boom"))
    middleware = Logister::Middleware.new(->(_env) { raise error })
    assert_same error, assert_raises(error.class) { middleware.call(env) }
    @reports.last&.fetch(:context)
  end

  def test_headers_are_allowlisted_and_names_use_the_shared_key_rule
    Logister.configuration.capture_headers = ["X-Tenant", "X-Auth-Token"]
    context = call_failing(failing_env(
      "https://example.com/widgets",
      "HTTP_PROXY_AUTHORIZATION" => "Basic Zm9vOmJhcg==",
      "HTTP_AUTHORIZATION" => "Bearer abc",
      "HTTP_COOKIE" => "sid=1",
      "HTTP_X_AMZ_SECURITY_TOKEN" => "aws",
      "HTTP_X_SHOPIFY_HMAC_SHA256" => "hmac",
      "HTTP_X_AUTH_TOKEN" => "tok",
      "HTTP_X_TENANT" => "acme",
      "HTTP_USER_AGENT" => "Minitest",
      "HTTP_TRACEPARENT" => "00-#{'a' * 32}-#{'b' * 16}-01"
    ))

    headers = context.fetch(:headers)
    assert_equal "Minitest", headers["User-Agent"]
    assert_equal "acme", headers["X-Tenant"]
    assert_equal "[REDACTED]", headers["X-Auth-Token"]
    assert headers.key?("Traceparent")
    %w[Proxy-Authorization Authorization Cookie X-Amz-Security-Token X-Shopify-Hmac-Sha256].each do |name|
      refute headers.key?(name), "#{name} should not be captured"
    end
  end

  def test_url_and_referer_query_values_are_redacted
    context = call_failing(failing_env(
      "https://example.com/cb?token=abc&code=1&password=p",
      "HTTP_REFERER" => "https://idp.example/login?session_token=s&next=/home#frag"
    ))

    expected_url = "https://example.com/cb?token=[REDACTED]&code=1&password=[REDACTED]"
    expected_referer = "https://idp.example/login?session_token=[REDACTED]&next=/home"
    assert_equal expected_url, context[:url]
    assert_equal expected_url, context.dig(:request, :url)
    assert_equal expected_referer, context[:referer]
    assert_equal expected_referer, context.dig(:headers, "Referer")
  end

  def test_anonymize_ip_covers_forwarded_headers
    Logister.configuration.anonymize_ip = true
    context = call_failing(failing_env(
      "https://example.com/",
      "HTTP_X_FORWARDED_FOR" => "203.0.113.9, 2001:db8::1234:5678",
      "HTTP_X_REAL_IP" => "203.0.113.9"
    ))

    assert_equal "203.0.113.0, 2001:db8::/64", context.dig(:headers, "X-Forwarded-For")
    assert_equal "203.0.113.0", context.dig(:headers, "X-Real-Ip")
    refute_includes context.to_s, "203.0.113.9"
  end

  def test_context_failure_never_replaces_the_application_exception
    log = StringIO.new
    Logister.configuration.logger = Logger.new(log)
    request_class = ActionDispatch::Request.singleton_class
    request_class.alias_method :__logister_original_new, :new
    request_class.remove_method :new if request_class.instance_methods(false).include?(:new)
    request_class.define_method(:new) { |*| raise NameError, "uninitialized constant ActionDispatch" }

    error = RuntimeError.new("app failure")
    middleware = Logister::Middleware.new(->(_env) { raise error })
    assert_same error, assert_raises(RuntimeError) { middleware.call(failing_env) }
    assert_match(/middleware error report failed: NameError/, log.string)
    assert_empty @reports
  ensure
    request_class.remove_method :new
    request_class.alias_method :new, :__logister_original_new
    request_class.remove_method :__logister_original_new
  end

  def test_reporting_failure_never_replaces_the_application_exception
    Logister.reporter.define_singleton_method(:report_error) { |*| raise IOError, "disk" }
    error = ArgumentError.new("app failure")

    assert_nil call_failing(failing_env, error)
  end

  def test_plain_rack_without_action_dispatch_preserves_the_original_exception
    script = <<~RUBY
      require "rack"
      require "rack/mock"
      require "logister"
      abort "ActionDispatch loaded" if defined?(ActionDispatch)
      Logister.configure { |c| c.api_key = "k"; c.async = false; c.logger = Logger.new(nil) }
      contexts = []
      Logister.reporter.instance_variable_get(:@client).define_singleton_method(:publish) { |payload| contexts << payload[:context]; true }
      Custom = Class.new(StandardError)
      app = Logister::Middleware.new(->(_env) { raise Custom, "original" })
      begin
        app.call(Rack::MockRequest.env_for("http://example.com/plain?api_key=k&x=1", "HTTP_COOKIE" => "s=1"))
      rescue Custom => e
        context = contexts.fetch(0)
        puts [e.message, context[:path], context[:method], context[:url], context[:headers].to_h.key?("Cookie")].inspect
      end
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
    assert status.success?, output
    assert_equal '["original", "/plain", "GET", "http://example.com/plain?api_key=[REDACTED]&x=1", false]', output.strip
  end

  def test_set_user_does_not_leak_across_requests_on_a_reused_thread
    first = Logister::Middleware.new(lambda do |_env|
      Logister.set_user(id: 42, email: "first@example.com")
      raise "first"
    end)
    assert_raises(RuntimeError) { first.call(failing_env) }
    assert_equal({ id: 42, email: "first@example.com" }, @reports.last.dig(:context, :user))

    second = Logister::Middleware.new(->(_env) { raise "second" })
    assert_raises(RuntimeError) { second.call(failing_env) }
    assert_nil @reports.last.dig(:context, :user)

    Logister::Middleware.new(lambda do |_env|
      Logister.set_user(id: 7)
      [200, {}, []]
    end).call(failing_env)
    Logister.report_error(RuntimeError.new("after request"))
    assert_nil @reports.last.dig(:context, :user)
  end

  def test_clear_user_removes_identity_within_a_request
    Logister.set_user(id: 1)
    Logister.clear_user
    Logister.report_error(RuntimeError.new("x"))

    assert_nil @reports.last.dig(:context, :user)
  end
end
