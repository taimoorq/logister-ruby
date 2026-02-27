# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Logister
  class Client
    CONTENT_TYPE = 'application/json'

    def initialize(configuration)
      @configuration = configuration
      @worker_mutex  = Mutex.new
      @queue         = SizedQueue.new(@configuration.queue_size)
      @worker        = nil
      @running       = false

      # Cache values that are static for the lifetime of this client so we
      # don't allocate on every send_request call.
      @uri         = URI.parse(@configuration.endpoint).freeze
      @use_ssl     = @uri.scheme == 'https'
      @auth_header = "Bearer #{@configuration.api_key}".freeze
    end

    def publish(payload)
      return false unless ready?

      return publish_sync(payload) unless @configuration.async

      ensure_worker_started
      enqueue(payload)
    end

    def flush(timeout: 2)
      return true unless @configuration.async

      deadline = monotonic_now + timeout
      until @queue.empty?
        return false if monotonic_now > deadline

        sleep(0.01)
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
      @queue.push(payload, true)
      true
    rescue ThreadError
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
      loop do
        payload = @queue.pop
        break if payload.nil?

        publish_sync(payload)
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
        if attempts <= @configuration.max_retries
          sleep(@configuration.retry_base_interval * (2**(attempts - 1)))
          retry
        end

        @configuration.logger.warn("logister publish failed: #{e.class} #{e.message}")
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
        read_timeout: @configuration.timeout_seconds
      ) { |http| http.request(request) }

      return true if response.is_a?(Net::HTTPSuccess)

      raise "HTTP #{response.code}"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def ready?
      @configuration.enabled && !@configuration.api_key.to_s.empty?
    end
  end
end
