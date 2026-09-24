# frozen_string_literal: true

require "securerandom"
require "uri"

module Logister
  # Immutable request identity. Capturing this value lets a caller report a failed
  # request later without borrowing another concurrent request's identity.
  class TraceContext
    attr_reader :trace_id, :span_id, :parent_span_id, :request_id, :flags

    def initialize(trace_id: SecureRandom.hex(16), span_id: SecureRandom.hex(8), parent_span_id: nil, request_id: SecureRandom.uuid, flags: "01")
      @trace_id, @span_id, @parent_span_id, @request_id, @flags = [trace_id, span_id, parent_span_id, request_id, flags].map { |value| value&.dup&.freeze }
      freeze
    end

    def self.parse(value)
      match = /\A00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/.match(value.to_s)
      return unless match && match[1] != "0" * 32 && match[2] != "0" * 16
      {trace_id: match[1], parent_span_id: match[2], flags: match[3]}
    end

    def self.from_headers(traceparent: nil, request_id: nil)
      request_id = nil unless request_id.is_a?(String) && request_id.match?(/\A[A-Za-z0-9._:-]{1,200}\z/)
      new(**(parse(traceparent) || {}), request_id: request_id || SecureRandom.uuid)
    end

    def to_h
      {trace_id: trace_id, span_id: span_id, parent_span_id: parent_span_id, request_id: request_id}.compact
    end

    def child
      self.class.new(trace_id: trace_id, parent_span_id: span_id, request_id: request_id, flags: flags)
    end

    def traceparent = "00-#{trace_id}-#{span_id}-#{flags}"

    # Apply only to the exact destination origin. HTTP clients must call this on
    # each redirect hop, or disable redirects; never forward the returned headers.
    def headers_for(url, allowed_origins:)
      return {} unless self.class.parse(traceparent) && request_id.is_a?(String) && request_id.match?(/\A[A-Za-z0-9._:-]{1,200}\z/)
      origin = self.class.origin(url)
      return {} unless origin && allowed_origins.any? { |allowed| self.class.origin(allowed) == origin }
      {"traceparent" => traceparent, "x-request-id" => request_id}
    end

    def self.origin(url)
      uri = URI.parse(url.to_s)
      return unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
      [uri.scheme, uri.host.downcase, uri.port]
    rescue URI::InvalidURIError
      nil
    end
  end
end
