# frozen_string_literal: true

require 'socket'

module Logister
  class Middleware
    # Sensitive param key fragments matched case-insensitively.
    SENSITIVE_PARAM_RE = /password|token|secret|api_key|credit_card|cvv|ssn/i.freeze
    FILTERED           = '[FILTERED]'

    def initialize(app)
      @app = app

      # Cache values that are constant for the lifetime of this process so
      # they are not recomputed on every error.
      @hostname    = resolve_hostname.freeze
      @app_context = build_app_context.freeze
    end

    def call(env)
      @app.call(env)
    rescue StandardError => e
      Logister.report_error(
        e,
        context: {
          request: build_request_context(env),
          app:     @app_context
        }
      )
      raise
    end

    private

    def build_request_context(env)
      ctx = {
        id:         env['action_dispatch.request_id'],
        path:       env['PATH_INFO'],
        method:     env['REQUEST_METHOD'],
        ip:         remote_ip(env),
        user_agent: env['HTTP_USER_AGENT']
      }

      # Params — available if ActionDispatch has already parsed them.
      if (params = env['action_dispatch.request.parameters'])
        ctx[:params] = filter_params(params)
      end

      ctx.compact
    end

    def build_app_context
      ctx = { ruby: RUBY_VERSION, hostname: @hostname }
      ctx[:rails] = Rails::VERSION::STRING if defined?(Rails::VERSION)
      ctx
    end

    # Respect X-Forwarded-For set by proxies; fall back to REMOTE_ADDR.
    def remote_ip(env)
      forwarded = env['HTTP_X_FORWARDED_FOR']
      return env['REMOTE_ADDR'] if forwarded.nil? || forwarded.empty?

      first = forwarded.split(',').first
      first ? first.strip : env['REMOTE_ADDR']
    end

    # Filter out sensitive parameter values using a single Regexp so we avoid
    # allocating a downcased String for every param key on every error.
    def filter_params(params)
      params.each_with_object({}) do |(k, v), h|
        h[k] = k.to_s.match?(SENSITIVE_PARAM_RE) ? FILTERED : v
      end
    rescue StandardError
      {}
    end

    def resolve_hostname
      Socket.gethostname
    rescue StandardError
      'unknown'
    end
  end
end
