# frozen_string_literal: true

require 'json'
require 'net/http'
require 'digest'
require 'securerandom'
require 'time'
require 'uri'
require 'zlib'

module Logister
  class Client
    CONTENT_TYPE = 'application/json'
    BATCH_CONTENT_TYPE = 'application/x-ndjson'
    UNSUPPORTED_BATCH_STATUSES = %w[404 405 415 501].freeze

    class UnsupportedBatchEndpoint < StandardError; end

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
      @pending_mutex = Mutex.new
      @pending_condition = ConditionVariable.new
      @pending_count = 0

      # Cache values that are static for the lifetime of this client so we
      # don't allocate on every send_request call.
      @uri            = URI.parse(@configuration.endpoint).freeze
      @batch_uri      = URI.parse(@configuration.batch_endpoint).freeze
      @deployment_uri = URI.parse(@configuration.deployment_endpoint).freeze
      @use_ssl        = @uri.scheme == 'https'
      @batch_use_ssl  = @batch_uri.scheme == 'https'
      @deployment_use_ssl = @deployment_uri.scheme == 'https'
      @auth_header    = "Bearer #{@configuration.api_key}".freeze
    end

    def publish(payload)
      return false unless ready?

      payload = with_stable_uuid(payload)

      return publish_sync(payload) unless @configuration.async

      ensure_worker_started
      enqueue(payload)
    end

    def publish_deployment(payload)
      return false unless ready?

      publish_deployment_sync(payload)
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

      @running = false
      begin
        @queue.push(nil)
      rescue StandardError
        nil
      end
      @worker&.join(1)
      @worker = nil
      true
    end

    private

    def enqueue(payload)
      increment_pending
      @queue.push(payload, true)
      true
    rescue ThreadError
      complete_pending(1)
      @configuration.logger.warn('logister queue full; dropping event')
      false
    end

    def ensure_worker_started
      # Fast path — no lock needed if already running (GVL-safe on MRI).
      return if @running && @worker&.alive?

      @worker_mutex.synchronize do
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
        break if stop_after_batch
      end
    rescue StandardError => e
      @configuration.logger.warn("logister worker crashed: #{e.class} #{e.message}")
    ensure
      # Always clear running flag and attempt auto-restart after a crash so
      # events enqueued after the crash are not silently dropped.
      @running = false
    end

    def publish_sync(payload)
      attempts = 0
      begin
        attempts += 1
        send_request(payload)
      rescue StandardError => e
        if attempts <= @configuration.max_retries && retryable_error?(e)
          sleep(retry_delay(e, attempts))
          retry
        end

        @configuration.logger.warn("logister publish failed: #{e.class} #{e.message}")
        false
      end
    end

    def publish_batch_sync(payloads)
      attempts = 0
      begin
        attempts += 1
        send_batch_request(payloads)
      rescue UnsupportedBatchEndpoint
        payloads.map { |payload| publish_sync(payload) }.all?
      rescue RequestError => e
        if e.status == 413 && payloads.length > 1
          middle = (payloads.length / 2.0).ceil
          first_half_delivered = publish_batch_sync(payloads.first(middle))
          second_half_delivered = publish_batch_sync(payloads.drop(middle))
          return first_half_delivered && second_half_delivered
        end
        if attempts <= @configuration.max_retries && retryable_error?(e)
          sleep(retry_delay(e, attempts))
          retry
        end

        @configuration.logger.warn("logister batch publish failed: #{e.class} #{e.message}")
        false
      rescue StandardError => e
        if attempts <= @configuration.max_retries && retryable_error?(e)
          sleep(retry_delay(e, attempts))
          retry
        end

        @configuration.logger.warn("logister batch publish failed: #{e.class} #{e.message}")
        false
      end
    end

    def publish_deployment_sync(payload)
      attempts = 0
      begin
        attempts += 1
        send_deployment_request(payload)
      rescue StandardError => e
        if attempts <= @configuration.max_retries && retryable_error?(e)
          sleep(retry_delay(e, attempts))
          retry
        end

        @configuration.logger.warn("logister deployment publish failed: #{e.class} #{e.message}")
        false
      end
    end

    def send_request(payload)
      request = Net::HTTP::Post.new(@uri)
      request['Content-Type']  = CONTENT_TYPE
      request['Authorization'] = @auth_header
      request.body             = { event: payload }.to_json

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

    def send_batch_request(payloads)
      request = Net::HTTP::Post.new(@batch_uri)
      request['Content-Type'] = BATCH_CONTENT_TYPE
      request['Authorization'] = @auth_header
      request['X-Logister-Batch-Id'] = batch_id(payloads)

      body = payloads.map { |payload| { event: payload }.to_json }.join("\n") << "\n"
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
      request.body             = { deployment: payload }.to_json

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
        payload[:uuid] || payload['uuid'] || payload[:event_id] || payload['event_id']
      end
      Digest::SHA256.hexdigest(identifiers.join("\n"))
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

    def retryable_error?(error)
      return true unless error.is_a?(RequestError)

      [408, 425, 429].include?(error.status) || error.status >= 500
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

    def retry_delay(error, attempt)
      configured_cap = [@configuration.max_retry_delay.to_f, 0.0].max
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
