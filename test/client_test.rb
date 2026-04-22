require_relative "test_helper"
require "json"

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

    assert_equal true, client.send(:send_request, payload)
    refute_nil captured_request
    assert_equal "Bearer test-token", captured_request["Authorization"]
    assert_equal "application/json", captured_request["Content-Type"]

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
end
