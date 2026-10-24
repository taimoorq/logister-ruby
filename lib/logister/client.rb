# frozen_string_literal: true

require 'json'
require 'net/http'
require 'digest'
require 'securerandom'
require 'time'
require 'uri'
require 'zlib'
require 'ipaddr'
begin
  require 'openssl'
rescue LoadError
  nil
end
require_relative 'event_sanitizer'
require_relative 'redaction'

module Logister
  class Client
    CONTENT_TYPE = 'application/json'
    BATCH_CONTENT_TYPE = 'application/x-ndjson'
    UNSUPPORTED_BATCH_STATUSES = %w[404 405 415 501].freeze
    RETRYABLE_STATUSES = [408, 425, 429].freeze
    SYNC_MAX_RETRY_DELAY = 1.0
    RETRYABLE_ERRORS = [
      Timeout::Error, IOError, SocketError, SystemCallError,
      (OpenSSL::SSL::SSLError if defined?(OpenSSL::SSL::SSLError))
    ].compact.freeze

    class UnsupportedBatchEndpoint < StandardError; end

    # One event serialized on its own before batching. A payload that cannot be
    # encoded is dropped alone instead of failing every event batched with it.
    class Event
      attr_reader :uuid, :payload, :json

      def initialize(uuid:, payload:, json:)
        @uuid = uuid
        @payload = payload
        @json = json
        freeze
      end

      def [](key) = payload[key]
      def fetch(...) = payload.fetch(...)
      def key?(key) = payload.key?(key)
      def to_h = payload
    end

    class RequestError < StandardError
      attr_reader :status, :retry_after

      def initialize(status, retry_after: nil)
        @status = status.to_i
        @retry_after = retry_after
        super("HTTP #{status}")
      end
    end

    def initialize(configuration)
      @configuration = configuration
      @worker_mutex  = Mutex.new
      @queue         = SizedQueue.new(@configuration.queue_size)
      @worker        = nil
      @running       = false
      @stopping      = false
      @pending_mutex = Mutex.new
      @pending_condition = ConditionVariable.new
      @pending_count = 0
      @delivery_mutex = Mutex.new
      @delivery_counts = { queued_events: 0, acknowledged_events: 0, unconfirmed_events: 0,
                           queue_full_events: 0, retry_attempts: 0 }

      # Cache values that are static for the lifetime of this client so we
      # don't allocate on every send_request call.
      @uri            = URI.parse(@configuration.endpoint).freeze
      @batch_uri      = URI.parse(@configuration.batch_endpoint).freeze
      @deployment_uri = URI.parse(@configuration.deployment_endpoint).freeze
      @use_ssl        = @uri.scheme == 'https'
      @batch_use_ssl  = @batch_uri.scheme == 'https'
      @deployment_use_ssl = @deployment_uri.scheme == 'https'
      @auth_header    = "Bearer #{@configuration.api_key}".freeze
      @redact_keys    = Redaction.normalize_keys(@configuration.redact_keys)
      @batch_unsupported = false
      warn_insecure_endpoints
    end

    def publish(payload)
      return false if ReportingScope.suppressed?
      return false unless ready?

      event = encode_event(with_stable_uuid(payload))
      return false unless event

      return publish_sync(event) unless @configuration.async

      ensure_worker_started
      enqueue(event)
    rescue StandardError => e
      warn_internal("logister publish failed: #{e.class}")
      false
    end

    def publish_deployment(payload)
      return false unless ready?

      publish_deployment_sync(payload)
    rescue StandardError => e
      warn_internal("logister deployment publish failed: #{e.class}")
      false
    end

    def flush(timeout: 2)
      return true unless @configuration.async

      deadline = monotonic_now + timeout
      @pending_mutex.synchronize do
        while @pending_count.positive?
          remaining = deadline - monotonic_now
          return false unless remaining.positive?

          @pending_condition.wait(@pending_mutex, [remaining, 0.05].min)
        end
      end

      true
    end

    def shutdown
      return true unless @configuration.async

      worker = @worker_mutex.synchronize do
        @stopping = true
        begin
          @queue.push(nil, true)
        rescue ThreadError
          # A full queue will be drained by the worker, which also checks the
          # stopping flag. Never block the caller waiting to enqueue a sentinel.
        end
        @worker
      end
      worker&.join(1)
      !worker&.alive?
    end

    # Process-local counters, never an assertion of exactly-once server receipt.
    def delivery_stats
      @delivery_mutex.synchronize { @delivery_counts.dup }
        .merge(pending_events: @pending_mutex.synchronize { @pending_count })
    end

    private

    def enqueue(payload)
      @worker_mutex.synchronize do
        return false if @stopping

        increment_pending
        @queue.push(payload, true)
      end
      record_delivery(:queued_events, 1)
      true
    rescue ThreadError
      complete_pending(1)
      record_delivery(:queue_full_events, 1, reason: 'queue_full')
      warn_internal('logister queue full; dropping event')
      false
    end

    def ensure_worker_started
      # Fast path — no lock needed if already running (GVL-safe on MRI).
      return if @running && @worker&.alive?

      @worker_mutex.synchronize do
        return if @stopping
        return if @running && @worker&.alive?

        @running = true
        @worker  = Thread.new { run_worker }
        @worker.name = 'logister-worker'
      end
    end

    def run_worker
      stop_after_batch = false
      loop do
        payload = @queue.pop
        break if payload.nil?

        batch = [payload]
        deadline = monotonic_now + batch_interval

        while batch.length < batch_size && monotonic_now < deadline
          begin
            queued = @queue.pop(true)
            if queued.nil?
              stop_after_batch = true
              break
            end
            batch << queued
          rescue ThreadError
            remaining = deadline - monotonic_now
            sleep([remaining, 0.005].min) if remaining.positive?
          end
        end

        publish_batch_sync(batch)
        complete_pending(batch.length)
        break if stop_after_batch || (@stopping && @queue.empty?)
      end
    rescue StandardError => e
      warn_internal("logister worker crashed: #{e.class}")
    ensure
      # Always clear running flag and attempt auto-restart after a crash so
      # events enqueued after the crash are not silently dropped.
      @running = false
    end

    # Synchronous mode delivers on the caller's thread, so it uses a small retry
    # cap and short waits instead of the background worker's limits.
    def publish_sync(event)
      publish_single(event, max_retries: sync_max_retries, max_delay: SYNC_MAX_RETRY_DELAY)
    end

    def publish_single(event, max_retries: @configuration.max_retries.to_i, max_delay: nil)
      event = coerce_event(event)
      return false unless event

      attempts = 0
      begin
        attempts += 1
        delivered = send_request(event)
        unless delivered
          record_delivery(:unconfirmed_events, 1, reason: 'no_acknowledgment')
          return false
        end
        record_delivery(:acknowledged_events, 1)
        true
      rescue StandardError => e
        if attempts <= max_retries && retryable_error?(e)
          record_delivery(:retry_attempts, 1, reason: failure_reason(e))
          sleep(retry_delay(e, attempts, max_delay: max_delay))
          retry
        end

        record_delivery(:unconfirmed_events, 1, reason: failure_reason(e))
        warn_internal("logister publish failed: #{e.class}")
        false
      end
    end

    def publish_batch_sync(items)
      payloads = items.filter_map { |item| coerce_event(item) }
      all_encoded = payloads.length == items.length
      return all_encoded if payloads.empty?

      deliver_batch(payloads) && all_encoded
    end

    def deliver_batch(payloads)
      return publish_each(payloads) if @batch_unsupported

      attempts = 0
      begin
        attempts += 1
        delivered = send_batch_request(payloads)
        unless delivered
          record_delivery(:unconfirmed_events, payloads.length, reason: 'no_acknowledgment')
          return false
        end
        record_delivery(:acknowledged_events, payloads.length)
        true
      rescue UnsupportedBatchEndpoint
        # Older servers keep this answer for the life of the client; stop paying
        # for a failed batch request before every fallback.
        @batch_unsupported = true
        publish_each(payloads)
      rescue StandardError => e
        if e.is_a?(RequestError) && e.status == 413 && payloads.length > 1
          middle = (payloads.length / 2.0).ceil
          first_half_delivered = deliver_batch(payloads.first(middle))
          second_half_delivered = deliver_batch(payloads.drop(middle))
          return first_half_delivered && second_half_delivered
        end
        if attempts <= @configuration.max_retries.to_i && retryable_error?(e)
          record_delivery(:retry_attempts, 1, reason: failure_reason(e))
          sleep(retry_delay(e, attempts))
          retry
        end

        record_delivery(:unconfirmed_events, payloads.length, reason: failure_reason(e))
        warn_internal("logister batch publish failed: #{e.class}")
        false
      end
    end

    def publish_each(events)
      events.map { |event| publish_single(event) }.all?
    end

    def publish_deployment_sync(payload)
      attempts = 0
      begin
        attempts += 1
        send_deployment_request(payload)
      rescue StandardError => e
        if attempts <= sync_max_retries && retryable_error?(e)
          sleep(retry_delay(e, attempts, max_delay: SYNC_MAX_RETRY_DELAY))
          retry
        end

        warn_internal("logister deployment publish failed: #{e.class}")
        false
      end
    end

    def send_request(event)
      request = Net::HTTP::Post.new(@uri)
      request['Content-Type']  = CONTENT_TYPE
      request['Authorization'] = @auth_header
      request.body             = coerce_event!(event).json

      response = Net::HTTP.start(
        @uri.host,
        @uri.port,
        use_ssl:      @use_ssl,
        open_timeout: @configuration.timeout_seconds,
        read_timeout: @configuration.timeout_seconds,
        write_timeout: @configuration.timeout_seconds
      ) { |http| http.request(request) }

      return true if response.is_a?(Net::HTTPSuccess)

      raise request_error(response)
    end

    def send_batch_request(events)
      events = events.map { |event| coerce_event!(event) }
      request = Net::HTTP::Post.new(@batch_uri)
      request['Content-Type'] = BATCH_CONTENT_TYPE
      request['Authorization'] = @auth_header
      request['X-Logister-Batch-Id'] = batch_id(events)

      body = events.map(&:json).join("\n") << "\n"
      if @configuration.batch_compression
        request['Content-Encoding'] = 'gzip'
        body = Zlib.gzip(body)
      end
      request.body = body

      response = Net::HTTP.start(
        @batch_uri.host,
        @batch_uri.port,
        use_ssl: @batch_use_ssl,
        open_timeout: @configuration.timeout_seconds,
        read_timeout: @configuration.timeout_seconds,
        write_timeout: @configuration.timeout_seconds
      ) { |http| http.request(request) }

      return true if response.is_a?(Net::HTTPSuccess)
      raise UnsupportedBatchEndpoint, "HTTP #{response.code}" if UNSUPPORTED_BATCH_STATUSES.include?(response.code)

      raise request_error(response)
    end

    def send_deployment_request(payload)
      request = Net::HTTP::Post.new(@deployment_uri)
      request['Content-Type']  = CONTENT_TYPE
      request['Authorization'] = @auth_header
      request.body             = JSON.generate({ deployment: EventSanitizer.call(payload, extra_keys: @redact_keys) })

      response = Net::HTTP.start(
        @deployment_uri.host,
        @deployment_uri.port,
        use_ssl:      @deployment_use_ssl,
        open_timeout: @configuration.timeout_seconds,
        read_timeout: @configuration.timeout_seconds,
        write_timeout: @configuration.timeout_seconds
      ) { |http| http.request(request) }

      return true if response.is_a?(Net::HTTPSuccess)

      raise request_error(response)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def failure_reason(error)
      return "http_#{error.status}" if error.is_a?(RequestError)
      return 'timeout' if error.is_a?(Timeout::Error)

      'transport_error'
    end

    def record_delivery(counter, count, reason: nil)
      @delivery_mutex.synchronize { @delivery_counts[counter] += count }
      observer = @configuration.delivery_observer
      return unless observer

      ReportingScope.suppress do
        observer.call({ outcome: counter.to_s, count: count, reason: reason }.compact.freeze)
      end
    rescue StandardError
      # Counters survive observer failure; never report this through telemetry.
      nil
    end

    def with_stable_uuid(payload)
      attributes = payload.to_h.dup
      key = attributes.keys.any? { |candidate| candidate.is_a?(String) } ? 'uuid' : :uuid
      uuid = [attributes[:uuid], attributes['uuid']].find { |value| !blank_identifier?(value) }
      event_id = [attributes[:event_id], attributes['event_id']].find { |value| !blank_identifier?(value) }

      attributes.delete(:uuid)
      attributes.delete('uuid')
      attributes.delete(:event_id) if blank_identifier?(attributes[:event_id])
      attributes.delete('event_id') if blank_identifier?(attributes['event_id'])
      attributes[key] = uuid || event_id || SecureRandom.uuid
      attributes
    end

    def blank_identifier?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def batch_id(payloads)
      identifiers = payloads.map do |payload|
        next payload.uuid if payload.is_a?(Event)

        payload[:uuid] || payload['uuid'] || payload[:event_id] || payload['event_id']
      end
      Digest::SHA256.hexdigest(identifiers.join("\n"))
    end

    # Sanitizes, redacts, and serializes one event. Oversized events are retried
    # with compact limits; an event that still cannot be encoded is dropped and
    # counted without affecting any other event.
    def encode_event(payload)
      uuid = payload[:uuid] || payload['uuid']
      [EventSanitizer::DEFAULT_LIMITS, EventSanitizer::COMPACT_LIMITS].each do |limits|
        sanitized = EventSanitizer.call(payload, extra_keys: @redact_keys, limits: limits)
        json = JSON.generate({ event: sanitized })
        return Event.new(uuid: uuid.to_s, payload: sanitized, json: json) if json.bytesize <= max_event_bytes
      end

      record_delivery(:unconfirmed_events, 1, reason: 'event_too_large')
      warn_internal('logister dropped an event larger than max_event_bytes')
      nil
    rescue StandardError => e
      record_delivery(:unconfirmed_events, 1, reason: 'serialization_error')
      warn_internal("logister could not serialize an event: #{e.class}")
      nil
    end

    def coerce_event(item)
      return item if item.is_a?(Event)

      encode_event(with_stable_uuid(item))
    end

    def coerce_event!(item)
      coerce_event(item) || raise(ArgumentError, 'event could not be encoded')
    end

    def max_event_bytes
      [@configuration.max_event_bytes.to_i, 1024].max
    end

    def sync_max_retries
      [[@configuration.sync_max_retries.to_i, 0].max, @configuration.max_retries.to_i].min
    end

    def warn_internal(message)
      @configuration.logger&.warn(message)
    rescue StandardError
      nil
    end

    def warn_insecure_endpoints
      [@uri, @batch_uri, @deployment_uri].uniq { |uri| [uri.host, uri.port] }.each do |uri|
        next unless uri.scheme == 'http' && !loopback_host?(uri.host)

        warn_internal("logister endpoint #{uri.scheme}://#{uri.host} is not HTTPS; the API key and events are sent unencrypted")
      end
    end

    def loopback_host?(host)
      name = host.to_s.downcase.delete_prefix('[').delete_suffix(']')
      return true if name == 'localhost' || name.end_with?('.localhost')

      IPAddr.new(name).loopback?
    rescue ArgumentError
      false
    end

    def batch_size
      [@configuration.batch_size.to_i, 1].max
    end

    def batch_interval
      [@configuration.batch_interval.to_f, 0.0].max
    end

    def increment_pending
      @pending_mutex.synchronize { @pending_count += 1 }
    end

    def complete_pending(count)
      @pending_mutex.synchronize do
        @pending_count = [@pending_count - count, 0].max
        @pending_condition.broadcast if @pending_count.zero?
      end
    end

    # Only transport failures and transient HTTP statuses are retried; a bug or
    # an unencodable payload fails once instead of being repeated.
    def retryable_error?(error)
      return RETRYABLE_STATUSES.include?(error.status) || error.status >= 500 if error.is_a?(RequestError)

      RETRYABLE_ERRORS.any? { |klass| error.is_a?(klass) }
    end

    def request_error(response)
      RequestError.new(response.code, retry_after: retry_after_seconds(response['Retry-After']))
    end

    def retry_after_seconds(value)
      header = value.to_s.strip
      return nil if header.empty?

      seconds = Float(header, exception: false)
      return [seconds, 0.0].max if seconds&.finite?

      [Time.httpdate(header) - Time.now, 0.0].max
    rescue ArgumentError
      nil
    end

    def retry_delay(error, attempt, max_delay: nil)
      configured_cap = [@configuration.max_retry_delay.to_f, 0.0].max
      configured_cap = [configured_cap, max_delay].min if max_delay
      base_delay = if error.is_a?(RequestError) && !error.retry_after.nil?
                     error.retry_after.to_f
                   else
                     @configuration.retry_base_interval.to_f * (2**(attempt - 1))
                   end
      bounded_delay = [[base_delay, 0.0].max, configured_cap].min
      jitter_ratio = @configuration.retry_jitter.to_f.clamp(0.0, 1.0)
      jitter = bounded_delay * jitter_ratio * rand

      [bounded_delay + jitter, configured_cap].min
    end

    def ready?
      @configuration.enabled && !@configuration.api_key.to_s.empty?
    end
  end
end
