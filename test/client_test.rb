require_relative "test_helper"
require "json"
require "zlib"

class ClientTest < Minitest::Test
  FakeHttp = Struct.new(:captured_request) do
    def request(request)
      self.captured_request = request
      Net::HTTPSuccess.new("1.1", "200", "OK")
    end
  end

  def test_send_request_wraps_payload_under_event_root_and_sets_auth_header
    client = Logister::Client.new(Logister.configuration)
    payload = { event_type: "log", message: "hello", context: { service: "demo" } }

    captured_request = nil
    captured_options = nil
    net_http_singleton = Net::HTTP.singleton_class
    original_method_name = :__logister_test_original_start

    net_http_singleton.alias_method original_method_name, :start
    net_http_singleton.remove_method :start
    net_http_singleton.define_method(:start) do |*_args, **kwargs, &block|
      fake_http = FakeHttp.new
      response = block.call(fake_http)
      captured_request = fake_http.captured_request
      captured_options = kwargs
      response
    end

    assert_equal true, client.send(:send_request, payload)
    refute_nil captured_request
    assert_equal "Bearer test-token", captured_request["Authorization"]
    assert_equal "application/json", captured_request["Content-Type"]
    assert_equal 2, captured_options.fetch(:open_timeout)
    assert_equal 2, captured_options.fetch(:read_timeout)
    assert_equal 2, captured_options.fetch(:write_timeout)

    body = JSON.parse(captured_request.body)
    event = body.fetch("event")
    assert_equal "log", event.fetch("event_type")
    assert_equal "hello", event.fetch("message")
    assert_equal({ "service" => "demo" }, event.fetch("context"))
  ensure
    if net_http_singleton.method_defined?(:start)
      net_http_singleton.remove_method :start
    end
    if net_http_singleton.method_defined?(original_method_name)
      net_http_singleton.alias_method :start, original_method_name
      net_http_singleton.remove_method original_method_name
    end
  end

  def test_publish_deployment_wraps_payload_under_deployment_root
    config = Logister.configuration
    config.deployment_endpoint = "https://example.com/api/v1/deployments"
    client = Logister::Client.new(config)
    payload = {
      release: "checkout@2026.06.18",
      environment: "production",
      repository: "acme/checkout",
      commit_sha: "abc1234",
      branch: "main"
    }

    captured_request = nil
    net_http_singleton = Net::HTTP.singleton_class
    original_method_name = :__logister_test_original_start

    net_http_singleton.alias_method original_method_name, :start
    net_http_singleton.remove_method :start
    net_http_singleton.define_method(:start) do |*_args, **_kwargs, &block|
      fake_http = FakeHttp.new
      response = block.call(fake_http)
      captured_request = fake_http.captured_request
      response
    end

    assert_equal true, client.publish_deployment(payload)
    refute_nil captured_request
    assert_equal "/api/v1/deployments", captured_request.path
    assert_equal "Bearer test-token", captured_request["Authorization"]

    body = JSON.parse(captured_request.body)
    deployment = body.fetch("deployment")
    assert_equal "checkout@2026.06.18", deployment.fetch("release")
    assert_equal "production", deployment.fetch("environment")
    assert_equal "acme/checkout", deployment.fetch("repository")
    assert_equal "abc1234", deployment.fetch("commit_sha")
    assert_equal "main", deployment.fetch("branch")
  ensure
    if net_http_singleton.method_defined?(:start)
      net_http_singleton.remove_method :start
    end
    if net_http_singleton.method_defined?(original_method_name)
      net_http_singleton.alias_method :start, original_method_name
      net_http_singleton.remove_method original_method_name
    end
  end

  def test_publish_assigns_a_stable_uuid_before_retryable_delivery
    client = Logister::Client.new(Logister.configuration)
    captured = nil
    client.define_singleton_method(:publish_sync) do |payload|
      captured = payload
      true
    end

    assert_equal true, client.publish(event_type: "log", message: "hello")
    assert_match(/\A[0-9a-f-]{36}\z/, captured.fetch(:uuid))
  end

  def test_publish_replaces_blank_identifier_keys_with_a_stable_uuid
    client = Logister::Client.new(Logister.configuration)
    captured = nil
    client.define_singleton_method(:publish_sync) do |payload|
      captured = payload
      true
    end

    assert_equal true, client.publish("uuid" => nil, event_id: " ", event_type: "log", message: "hello")
    assert_match(/\A[0-9a-f-]{36}\z/, captured.fetch("uuid"))
    refute captured.key?(:event_id)
  end

  def test_batch_retry_reuses_the_same_event_and_batch_identifiers
    config = Logister.configuration
    config.max_retries = 1
    config.retry_base_interval = 0
    client = Logister::Client.new(config)
    payloads = [
      { uuid: "11111111-1111-4111-8111-111111111111", event_type: "log", message: "one" },
      { uuid: "22222222-2222-4222-8222-222222222222", event_type: "metric", message: "two" }
    ]
    attempts = []
    client.define_singleton_method(:send_batch_request) do |batch|
      attempts << {
        event_ids: batch.map { |event| event.fetch(:uuid) },
        batch_id: batch_id(batch)
      }
      raise Logister::Client::RequestError, 503 if attempts.one?

      true
    end

    assert_equal true, client.send(:publish_batch_sync, payloads)
    assert_equal 2, attempts.size
    assert_equal attempts.first, attempts.last
  end

  def test_unsupported_batch_endpoint_falls_back_to_stable_single_events
    client = Logister::Client.new(Logister.configuration)
    payloads = [
      { uuid: "11111111-1111-4111-8111-111111111111", event_type: "log", message: "one" },
      { uuid: "22222222-2222-4222-8222-222222222222", event_type: "metric", message: "two" }
    ]
    delivered_ids = []
    client.define_singleton_method(:send_batch_request) do |_batch|
      raise Logister::Client::UnsupportedBatchEndpoint, "HTTP 404"
    end
    client.define_singleton_method(:publish_sync) do |event|
      delivered_ids << event.fetch(:uuid)
      true
    end

    assert_equal true, client.send(:publish_batch_sync, payloads)
    assert_equal payloads.map { |event| event.fetch(:uuid) }, delivered_ids
  end

  def test_unsupported_batch_fallback_attempts_every_event_after_a_failure
    client = Logister::Client.new(Logister.configuration)
    payloads = [
      { uuid: "11111111-1111-4111-8111-111111111111", event_type: "log", message: "one" },
      { uuid: "22222222-2222-4222-8222-222222222222", event_type: "log", message: "two" },
      { uuid: "33333333-3333-4333-8333-333333333333", event_type: "log", message: "three" }
    ]
    attempted = []
    client.define_singleton_method(:send_batch_request) do |_batch|
      raise Logister::Client::UnsupportedBatchEndpoint, "HTTP 404"
    end
    client.define_singleton_method(:publish_sync) do |event|
      attempted << event.fetch(:uuid)
      event.fetch(:message) != "one"
    end

    assert_equal false, client.send(:publish_batch_sync, payloads)
    assert_equal payloads.map { |event| event.fetch(:uuid) }, attempted
  end

  def test_413_split_attempts_the_second_half_when_the_first_half_fails
    client = Logister::Client.new(Logister.configuration)
    payloads = 4.times.map do |index|
      {
        uuid: format("%08d-1111-4111-8111-111111111111", index),
        event_type: "log",
        message: "event #{index}"
      }
    end
    attempted_batches = []
    client.define_singleton_method(:send_batch_request) do |batch|
      attempted_batches << batch.map { |event| event.fetch(:message) }
      raise Logister::Client::RequestError.new(413) if batch.length == 4

      batch.first.fetch(:message) != "event 0"
    end

    assert_equal false, client.send(:publish_batch_sync, payloads)
    assert_equal [4, 2, 2], attempted_batches.map(&:length)
    assert_equal ["event 2", "event 3"], attempted_batches.last
  end

  def test_retry_after_is_parsed_capped_and_used_for_retryable_responses
    config = Logister.configuration
    config.max_retries = 1
    config.max_retry_delay = 5
    config.retry_jitter = 0
    client = Logister::Client.new(config)
    attempts = 0
    sleeps = []
    client.define_singleton_method(:send_batch_request) do |_batch|
      attempts += 1
      raise Logister::Client::RequestError.new(429, retry_after: 120) if attempts == 1

      true
    end
    client.define_singleton_method(:sleep) { |seconds| sleeps << seconds }

    payload = [{ uuid: SecureRandom.uuid, event_type: "log", message: "retry" }]
    assert_equal true, client.send(:publish_batch_sync, payload)
    assert_equal [5.0], sleeps
    assert_equal 3.0, client.send(:retry_after_seconds, "3")
    http_date_delay = client.send(:retry_after_seconds, (Time.now + 10).httpdate)
    assert_operator http_date_delay, :>, 8.5
    assert_operator http_date_delay, :<=, 10.0
    assert_nil client.send(:retry_after_seconds, "not-a-delay")

    config.max_retry_delay = 10
    config.retry_jitter = 0.2
    client.define_singleton_method(:rand) { 0.5 }
    delay = client.send(:retry_delay, Logister::Client::RequestError.new(503, retry_after: 2), 1)
    assert_in_delta 2.2, delay
  end

  def test_batch_request_uses_gzip_ndjson_and_deterministic_batch_id
    config = Logister.configuration
    config.batch_endpoint = "https://example.com/api/v1/ingest_events/batch"
    config.batch_compression = true
    client = Logister::Client.new(config)
    payloads = [
      { uuid: "11111111-1111-4111-8111-111111111111", event_type: "log", message: "one" },
      { uuid: "22222222-2222-4222-8222-222222222222", event_type: "metric", message: "two" }
    ]

    captured_request = nil
    net_http_singleton = Net::HTTP.singleton_class
    original_method_name = :__logister_batch_test_original_start
    net_http_singleton.alias_method original_method_name, :start
    net_http_singleton.remove_method :start
    net_http_singleton.define_method(:start) do |*_args, **_kwargs, &block|
      fake_http = FakeHttp.new
      response = block.call(fake_http)
      captured_request = fake_http.captured_request
      response
    end

    assert_equal true, client.send(:send_batch_request, payloads)
    assert_equal "/api/v1/ingest_events/batch", captured_request.path
    assert_equal "application/x-ndjson", captured_request["Content-Type"]
    assert_equal "gzip", captured_request["Content-Encoding"]
    assert_equal client.send(:batch_id, payloads), captured_request["X-Logister-Batch-Id"]

    envelopes = Zlib.gunzip(captured_request.body).lines.map { |line| JSON.parse(line) }
    assert_equal payloads.map { |payload| payload[:uuid] }, envelopes.map { |row| row.fetch("event").fetch("uuid") }
  ensure
    if net_http_singleton&.method_defined?(:start)
      net_http_singleton.remove_method :start
    end
    if net_http_singleton&.method_defined?(original_method_name)
      net_http_singleton.alias_method :start, original_method_name
      net_http_singleton.remove_method original_method_name
    end
  end
end
