require_relative "test_helper"
require "timeout"

class DeliveryObservabilityTest < Minitest::Test
  def test_exhausted_timeout_is_unconfirmed_and_observer_contains_no_payload
    config = Logister.configuration
    config.max_retries = 2
    config.retry_base_interval = 0
    events = []
    config.delivery_observer = ->(event) { events << event }
    client = Logister::Client.new(config)
    client.define_singleton_method(:send_batch_request) { |_payloads| raise Net::ReadTimeout, 'private-address' }

    refute client.send(:publish_batch_sync, [{ uuid: 'secret-id', message: 'private-body' }])
    assert_equal 2, client.delivery_stats[:retry_attempts]
    assert_equal 1, client.delivery_stats[:unconfirmed_events]
    assert_equal 0, client.delivery_stats[:acknowledged_events]
    assert_equal({ outcome: 'unconfirmed_events', count: 1, reason: 'timeout' }, events.last)
    refute_match(/private|secret/, events.to_json)
  end

  def test_split_batches_count_each_event_outcome_once
    config = Logister.configuration
    config.max_retries = 0
    client = Logister::Client.new(config)
    client.define_singleton_method(:send_batch_request) do |payloads|
      raise Logister::Client::RequestError.new(413) if payloads.size > 1
      raise Logister::Client::RequestError.new(400) if payloads.first[:uuid] == 'rejected'
      true
    end

    refute client.send(:publish_batch_sync, [{ uuid: 'accepted' }, { uuid: 'rejected' }])
    assert_equal 1, client.delivery_stats[:acknowledged_events]
    assert_equal 1, client.delivery_stats[:unconfirmed_events]
  end

  def test_observer_cannot_recurse_or_change_success
    client = Logister::Client.new(Logister.configuration)
    calls = 0
    client.define_singleton_method(:send_request) { |_payload| true }
    Logister.configuration.delivery_observer = lambda do |_event|
      calls += 1
      refute client.publish(message: 'feedback')
      raise 'observer unavailable'
    end

    assert client.publish(message: 'one event')
    assert_equal 1, calls
    assert_equal 1, client.delivery_stats[:acknowledged_events]
  end

  def test_full_queue_and_in_flight_shutdown_stay_bounded_and_accounted
    config = Logister.configuration
    config.async = true
    config.queue_size = 1
    config.batch_interval = 0
    client = Logister::Client.new(config)
    entered = Queue.new
    release = Queue.new
    calls = 0
    client.define_singleton_method(:send_batch_request) do |_payloads|
      calls += 1
      if calls == 1
        entered << true
        release.pop
      end
      true
    end

    assert client.publish(message: 'in flight')
    Timeout.timeout(2) { entered.pop }
    assert client.publish(message: 'queued')
    refute client.publish(message: 'queue full')
    refute Timeout.timeout(2) { client.shutdown }
    refute client.publish(message: 'after shutdown')
    release << true
    assert client.flush(timeout: 2)
    assert client.shutdown
    assert_equal 2, client.delivery_stats[:queued_events]
    assert_equal 2, client.delivery_stats[:acknowledged_events]
    assert_equal 1, client.delivery_stats[:queue_full_events]
    assert_equal 0, client.delivery_stats[:pending_events]
  ensure
    release << true if release
    client&.shutdown
  end
end
