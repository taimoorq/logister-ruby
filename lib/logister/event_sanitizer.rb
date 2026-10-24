# frozen_string_literal: true

require 'date'
require_relative 'redaction'

module Logister
  # Converts an event into JSON-safe primitives before it is serialized:
  # applies the shared redaction spec, scrubs invalid UTF-8, bounds string
  # length, collection size, nesting depth, and total key count. The limits stay
  # below the Logister ingest limits so one oversized event is trimmed locally
  # instead of being rejected by the server.
  class EventSanitizer
    TRUNCATED = '[TRUNCATED]'
    TRUNCATION_MARKER_KEY = 'logister_truncated'

    # SDK-generated envelope fields: never redacted, so correlation survives.
    ENVELOPE_KEYS = Set.new(%w[
      uuid event_id event_type trace_id span_id parent_span_id request_id session_id
      requestId traceId spanId parentSpanId sessionId
    ]).freeze

    # Large, low-priority context collections are visited last so the key
    # budget is spent on the exception, request, and user context first.
    DEFERRED_CONTEXT_KEYS = Set.new(%w[breadcrumbs dependencyCalls]).freeze

    Limits = Struct.new(:max_string_bytes, :max_message_bytes, :max_items, :max_depth, :max_keys, keyword_init: true)

    DEFAULT_LIMITS = Limits.new(
      max_string_bytes: 16 * 1024,
      max_message_bytes: 32 * 1024,
      max_items: 100,
      max_depth: 10,
      max_keys: 400
    ).freeze

    COMPACT_LIMITS = Limits.new(
      max_string_bytes: 1024,
      max_message_bytes: 4096,
      max_items: 20,
      max_depth: 6,
      max_keys: 200
    ).freeze

    def self.call(payload, extra_keys: Redaction.configured_keys, limits: DEFAULT_LIMITS)
      new(extra_keys: extra_keys, limits: limits).sanitize_payload(payload)
    end

    def initialize(extra_keys:, limits:)
      @extra_keys = extra_keys
      @limits = limits
      @keys_used = 0
      @truncated = false
    end

    def sanitize_payload(payload)
      result = {}
      payload.to_h.each do |key, value|
        name = key.to_s
        result[key] = case name
                      when 'context'
                        sanitize_context(value)
                      when 'message'
                        value.nil? ? nil : string(value.to_s, @limits.max_message_bytes)
                      else
                        envelope_value(value)
                      end
        @keys_used += 1
      end
      result
    end

    private

    def sanitize_context(context)
      return sanitize(context, 1) unless context.is_a?(Hash)

      deferred, primary = context.to_a.partition { |key, _| DEFERRED_CONTEXT_KEYS.include?(key.to_s) }
      result = {}
      (primary + deferred).each do |key, value|
        unless take_key
          @truncated = true
          break
        end

        name = utf8(key.to_s)
        result[name] = if ENVELOPE_KEYS.include?(name)
                         envelope_value(value)
                       elsif Redaction.sensitive_key?(name, @extra_keys)
                         Redaction::REDACTED
                       else
                         sanitize(value, 2)
                       end
      end
      result[TRUNCATION_MARKER_KEY] = true if @truncated
      result
    end

    def envelope_value(value)
      case value
      when String then truncate(utf8(value), @limits.max_string_bytes)
      when Symbol then value.to_s
      when Hash, Array then sanitize(value, 1)
      else primitive(value)
      end
    end

    def sanitize(value, depth)
      case value
      when nil, true, false, Integer then value
      when Float then value.finite? ? value : value.to_s
      when String then string(value)
      when Symbol then string(value.to_s)
      when Hash then sanitize_hash(value, depth)
      when Array, Set then sanitize_array(value.to_a, depth)
      else sanitize_object(value, depth)
      end
    end

    def sanitize_hash(hash, depth)
      return mark_truncated(TRUNCATED) if depth > @limits.max_depth

      result = {}
      hash.each_with_index do |(key, value), index|
        if index >= @limits.max_items || !take_key
          @truncated = true
          break
        end

        key = utf8(key.to_s)
        result[key] = Redaction.sensitive_key?(key, @extra_keys) ? Redaction::REDACTED : sanitize(value, depth + 1)
      end
      result
    end

    def sanitize_array(array, depth)
      return mark_truncated(TRUNCATED) if depth > @limits.max_depth

      @truncated = true if array.length > @limits.max_items
      array.first(@limits.max_items).map { |item| sanitize(item, depth + 1) }
    end

    def sanitize_object(value, depth)
      case value
      when Time, DateTime then value.iso8601
      when Date then value.iso8601
      when Exception then { 'class' => value.class.name, 'message' => string(value.message.to_s) }
      when Struct then sanitize_hash(value.to_h, depth)
      else
        # Never enumerate lazy relations or IO-like objects; they can run
        # queries or block. Everything else uses its JSON representation.
        return string("#<#{value.class.name}>") if lazy_collection?(value)
        return string(value.to_s) unless value.respond_to?(:as_json)

        converted = value.as_json
        return string(value.to_s) if converted.equal?(value)

        sanitize(converted, depth)
      end
    rescue StandardError
      string("#<#{value.class.name}>")
    end

    def lazy_collection?(value)
      (defined?(ActiveRecord::Relation) && value.is_a?(ActiveRecord::Relation)) ||
        value.is_a?(Enumerator) || value.is_a?(IO) || value.is_a?(Proc)
    end

    def primitive(value)
      case value
      when nil, true, false, Integer then value
      when Float then value.finite? ? value : value.to_s
      else string(value.to_s)
      end
    end

    def string(value, max_bytes = @limits.max_string_bytes)
      # Bound regex work on huge strings, keeping enough slack that a credential
      # straddling the truncation point is still recognized and redacted.
      value = value.byteslice(0, max_bytes + 4096) if value.bytesize > max_bytes + 4096
      truncate(Redaction.scrub_string(utf8(value), @extra_keys), max_bytes)
    end

    def utf8(value)
      value = value.dup.force_encoding(Encoding::UTF_8) if value.encoding == Encoding::BINARY
      value = value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless value.encoding == Encoding::UTF_8
      value.valid_encoding? ? value : value.scrub
    rescue StandardError
      value.to_s.b.force_encoding(Encoding::UTF_8).scrub
    end

    def truncate(value, max_bytes)
      return value if value.bytesize <= max_bytes

      @truncated = true
      "#{value.byteslice(0, max_bytes).scrub('')}…#{TRUNCATED}"
    end

    def take_key
      return false if @keys_used >= @limits.max_keys

      @keys_used += 1
      true
    end

    def mark_truncated(value)
      @truncated = true
      value
    end
  end
end
