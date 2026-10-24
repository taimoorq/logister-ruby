require_relative "test_helper"
require "json"
require "openssl"

class ClientHardeningTest < Minitest::Test
  def build_client(sleeps: [], **settings)
    config = Logister.configuration
    settings.each { |key, value| config.public_send("#{key}=", value) }
    client = Logister::Client.new(config)
    client.define_singleton_method(:sleep) { |seconds| sleeps << seconds }
    client
  end

  def test_poison_event_is_dropped_alone_and_the_rest_of_the_batch_is_delivered
    client = build_client(max_retries: 3)
    sanitizer = Logister::EventSanitizer.singleton_class
    sanitizer.alias_method :__original_call, :call
    sanitizer.remove_method :call
    sanitizer.define_method(:call) do |payload, **kwargs|
      raise JSON::GeneratorError, "poison" if payload[:message] == "poison"

      __original_call(payload, **kwargs)
    end
    batches = []
    client.define_singleton_method(:send_batch_request) do |events|
      batches << events.map { |event| JSON.parse(event.json).dig("event", "message") }
      true
    end

    payloads = [
      { uuid: "1", message: "before" },
      { uuid: "2", message: "poison" },
      { uuid: "3", message: "invalid \xFF utf-8".dup.force_encoding("UTF-8"), context: { ratio: Float::NAN } }
    ]

    refute client.send(:publish_batch_sync, payloads)
    assert_equal [["before", "invalid � utf-8"]], batches
    stats = client.delivery_stats
    assert_equal 2, stats[:acknowledged_events]
    assert_equal 1, stats[:unconfirmed_events]
    assert_equal 0, stats[:retry_attempts]
  ensure
    sanitizer.remove_method :call
    sanitizer.alias_method :call, :__original_call
    sanitizer.remove_method :__original_call
  end

  def test_publish_redacts_the_serialized_event
    client = build_client
    bodies = []
    client.define_singleton_method(:send_request) do |event|
      bodies << event.json
      true
    end

    assert client.publish(
      event_type: "log",
      message: "token=abc",
      context: { url: "https://x.test/?password=p&page=1", user: { email: "a@b.c", api_token: "t" } }
    )
    body = JSON.parse(bodies.first).fetch("event")
    assert_equal "token=[REDACTED]", body["message"]
    assert_equal "https://x.test/?password=[REDACTED]&page=1", body.dig("context", "url")
    assert_equal({ "email" => "a@b.c", "api_token" => "[REDACTED]" }, body.dig("context", "user"))
  end

  def test_only_io_errors_and_transient_statuses_are_retried
    client = build_client
    retryable = [
      Net::ReadTimeout.new, Timeout::Error.new, IOError.new, EOFError.new, SocketError.new,
      Errno::ECONNRESET.new, Errno::ECONNREFUSED.new, OpenSSL::SSL::SSLError.new,
      Logister::Client::RequestError.new(503), Logister::Client::RequestError.new(429),
      Logister::Client::RequestError.new(408)
    ]
    permanent = [
      RuntimeError.new, NoMethodError.new, JSON::GeneratorError.new("x"), ArgumentError.new,
      Logister::Client::RequestError.new(400), Logister::Client::RequestError.new(401),
      Logister::Client::RequestError.new(413)
    ]

    retryable.each { |error| assert client.send(:retryable_error?, error), "#{error.class} should retry" }
    permanent.each { |error| refute client.send(:retryable_error?, error), "#{error.class} should not retry" }
  end

  def test_non_io_failure_is_not_retried
    client = build_client(max_retries: 3)
    calls = 0
    client.define_singleton_method(:send_batch_request) do |_events|
      calls += 1
      raise NoMethodError, "bug"
    end

    refute client.send(:publish_batch_sync, [{ uuid: "1", message: "m" }])
    assert_equal 1, calls
    assert_equal 0, client.delivery_stats[:retry_attempts]
  end

  def test_unsupported_batch_endpoint_is_memoized
    client = build_client
    batch_calls = 0
    single = []
    client.define_singleton_method(:send_batch_request) do |_events|
      batch_calls += 1
      raise Logister::Client::UnsupportedBatchEndpoint, "HTTP 404"
    end
    client.define_singleton_method(:send_request) do |event|
      single << event.uuid
      true
    end

    assert client.send(:publish_batch_sync, [{ uuid: "1" }, { uuid: "2" }])
    assert client.send(:publish_batch_sync, [{ uuid: "3" }])
    assert_equal 1, batch_calls
    assert_equal %w[1 2 3], single
  end

  def test_sync_mode_uses_a_small_retry_cap_and_short_waits
    sleeps = []
    client = build_client(sleeps: sleeps, async: false, max_retries: 5, max_retry_delay: 30, retry_base_interval: 10, retry_jitter: 0)
    attempts = 0
    client.define_singleton_method(:send_request) do |_event|
      attempts += 1
      raise Logister::Client::RequestError.new(503, retry_after: 120)
    end

    refute client.publish(message: "sync")
    assert_equal 2, attempts
    assert_equal [1.0], sleeps
  end

  def test_background_fallback_keeps_the_configured_retry_budget
    client = build_client(max_retries: 2, retry_base_interval: 0)
    attempts = 0
    client.define_singleton_method(:send_request) do |_event|
      attempts += 1
      raise Errno::ECONNRESET
    end

    refute client.send(:publish_single, client.send(:coerce_event, { uuid: "1" }))
    assert_equal 3, attempts
  end

  def test_oversized_event_is_compacted_or_dropped
    client = build_client(max_event_bytes: 4096)
    bodies = []
    client.define_singleton_method(:send_request) do |event|
      bodies << event.json
      true
    end

    assert client.publish(message: "big", context: { blob: "x" * 20_000, list: Array.new(50) { "y" * 100 } })
    assert_operator bodies.last.bytesize, :<=, 4096
    assert_equal true, JSON.parse(bodies.last).dig("event", "context", "logister_truncated")

    refute client.publish(message: "too big", context: Array.new(200) { |index| ["k#{index}", "z" * 1000] }.to_h)
    assert_equal 1, client.delivery_stats[:unconfirmed_events]
  end

  def test_http_endpoints_warn_unless_loopback
    { "http://ingest.example.com/api/v1/ingest_events" => true,
      "http://localhost:3000/api/v1/ingest_events" => false,
      "http://127.0.0.1/api/v1/ingest_events" => false,
      "http://[::1]:3000/api/v1/ingest_events" => false,
      "https://ingest.example.com/api/v1/ingest_events" => false }.each do |endpoint, warns|
      log = StringIO.new
      config = Logister.configuration
      config.endpoint = endpoint
      config.batch_endpoint = nil
      config.deployment_endpoint = nil
      config.logger = Logger.new(log)
      Logister::Client.new(config)

      assert_equal warns, log.string.include?("not HTTPS"), endpoint
    end
  end
end
