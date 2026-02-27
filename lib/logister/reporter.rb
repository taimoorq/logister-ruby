# frozen_string_literal: true

require 'digest'
require 'time'
require 'set'

module Logister
  class Reporter
    def initialize(configuration)
      @configuration = configuration
      @client        = Client.new(configuration)

      # Pre-build values that are static for the lifetime of this reporter so
      # they are not allocated on every report_error / report_metric call.
      @static_context = {
        environment: @configuration.environment,
        service:     @configuration.service,
        release:     @configuration.release
      }.freeze

      # Normalise ignore_environments once into a frozen Set of Strings so
      # ignored_environment? never allocates a mapped Array.
      @ignored_envs = Set.new(@configuration.ignore_environments.map(&:to_s)).freeze

      # Cache the current-environment String to avoid repeated .to_s calls.
      @current_env = @configuration.environment.to_s.freeze

      # Compile the app-root stripping Regexp once; Dir.pwd is a syscall that
      # always returns a new String — do it exactly once here.
      app_root = Dir.pwd.to_s.freeze
      @app_root_re = /\A#{Regexp.escape(app_root)}\//.freeze

      # Register shutdown hook. Guard with a flag so multiple Reporter instances
      # (created by repeated Logister.configure calls) each shut down cleanly
      # without re-registering more handlers.
      @shutdown_registered = false
      register_shutdown_hook
    end

    def report_error(exception, context: {}, tags: {}, level: 'error', fingerprint: nil)
      return false if ignored_exception?(exception)
      return false if ignored_path?(context)

      merged_context = context.dup
      user = current_user_context
      merged_context[:user] = user if user

      payload = build_payload(
        event_type:  'error',
        level:       level,
        message:     "#{exception.class}: #{exception.message}",
        fingerprint: fingerprint || default_fingerprint(exception),
        context:     merged_context.merge(
          exception: {
            class:     exception.class.to_s,
            message:   exception.message.to_s,
            backtrace: Array(exception.backtrace).first(50)
          },
          tags: tags
        )
      )

      payload = apply_before_notify(payload)
      return false unless payload

      @client.publish(payload)
    end

    def report_metric(message:, level: 'info', context: {}, tags: {}, fingerprint: nil)
      return false if ignored_environment?
      return false if ignored_path?(context)

      payload = build_payload(
        event_type:  'metric',
        level:       level,
        message:     message,
        fingerprint: fingerprint || metric_fingerprint(message),
        context:     context.merge(tags: tags)
      )

      payload = apply_before_notify(payload)
      return false unless payload

      @client.publish(payload)
    end

    # Store user info for the current thread so it is automatically attached to
    # every error reported during this request.
    #
    #   Logister.set_user(id: current_user.id, email: current_user.email, name: current_user.name)
    #
    def set_user(id: nil, email: nil, name: nil, **extra)
      ctx = { id: id, email: email, name: name }.merge(extra).compact
      Thread.current[:logister_user] = ctx.empty? ? nil : ctx
    end

    def clear_user
      Thread.current[:logister_user] = nil
    end

    def flush(timeout: 2)
      @client.flush(timeout: timeout)
    end

    def shutdown
      @client.shutdown
    end

    private

    def register_shutdown_hook
      return if @shutdown_registered

      @shutdown_registered = true
      # Capture @client directly (not self) so the at_exit proc does not
      # retain the entire Reporter in the finalizer chain.
      client = @client
      at_exit { client.shutdown }
    end

    def current_user_context
      Thread.current[:logister_user]
    end

    def build_payload(event_type:, level:, message:, fingerprint:, context:)
      {
        event_type:  event_type,
        level:       level,
        message:     message,
        fingerprint: fingerprint,
        occurred_at: Time.now.utc.iso8601,
        # Merge static config context last so caller-supplied keys are not
        # overwritten, then merge the static values. The static_context Hash
        # is frozen and reused — only the new outer Hash is allocated.
        context:     @static_context.merge(context)
      }
    end

    def apply_before_notify(payload)
      hook = @configuration.before_notify
      return payload unless hook.respond_to?(:call)

      result = hook.call(payload)
      return nil if result == false || result.nil?

      result
    rescue StandardError => e
      @configuration.logger.warn("logister before_notify failed: #{e.class} #{e.message}")
      nil
    end

    def ignored_exception?(exception)
      return true if ignored_environment?

      @configuration.ignore_exceptions.any? do |item|
        if item.is_a?(Class)
          exception.is_a?(item)
        else
          exception.class.name == item.to_s
        end
      end
    end

    def ignored_environment?
      @ignored_envs.include?(@current_env)
    end

    def ignored_path?(context)
      path = context[:path] || context['path']
      return false if path.to_s.empty?

      path_s = path.to_s
      @configuration.ignore_paths.any? do |matcher|
        matcher.is_a?(Regexp) ? matcher.match?(path_s) : path_s.include?(matcher.to_s)
      end
    end

    # Cache metric fingerprints — metric messages are typically a small fixed
    # set of constants (e.g. 'db.query') so the SHA256 is identical every call.
    def metric_fingerprint(message)
      @metric_fingerprint_cache ||= {}
      key = message.to_s
      @metric_fingerprint_cache[key] ||=
        Digest::SHA256.hexdigest(key)[0, 32].freeze
    end

    def default_fingerprint(exception)
      # Prefer class + first backtrace location so that errors with dynamic
      # values in their message (e.g. "Couldn't find User with 'id'=42") still
      # group together across different IDs / UUIDs.
      location = Array(exception.backtrace).first.to_s
                                           .sub(/:in\s+.+$/, '')       # strip method name
                                           .sub(/\A.*\/gems\//, 'gems/') # normalise gem paths
                                           .sub(@app_root_re, '')       # strip app root (pre-compiled RE)

      if location.empty?
        # No backtrace — scrub dynamic tokens from the message before hashing.
        scrubbed = scrub_dynamic_values(exception.message.to_s)
        Digest::SHA256.hexdigest("#{exception.class}|#{scrubbed}")[0, 32]
      else
        Digest::SHA256.hexdigest("#{exception.class}|#{location}")[0, 32]
      end
    end

    # Strip values that vary per-occurrence but carry no grouping signal:
    #   - numeric IDs:  id=42, 'id'=42, id: 42
    #   - UUIDs
    #   - hex digests (≥8 hex chars)
    #   - quoted string values in ActiveRecord-style messages
    def scrub_dynamic_values(message)
      message
        .gsub(/\b(id['"]?\s*[=:]\s*)\d+/i,                                         '\1?')
        .gsub(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,   '?')
        .gsub(/\b[0-9a-f]{8,}\b/,                                                   '?')
        .gsub(/'[^']{1,64}'/,                                                        '?')
        .gsub(/\d+/,                                                                 '?')
    end
  end
end
