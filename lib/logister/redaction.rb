# frozen_string_literal: true

require 'uri'

module Logister
  # Shared default redaction spec used by every Logister SDK. Keep the key lists
  # and value patterns identical across SDKs; add project-specific keys through
  # `config.redact_keys` instead of changing these defaults.
  module Redaction
    REDACTED = '[REDACTED]'

    SENSITIVE_KEYS = Set.new(%w[
      password passwd pwd secret token apikey authorization proxyauthorization
      cookie setcookie sessiontoken sessionkey credential credentials privatekey
      clientsecret accesstoken refreshtoken idtoken authtoken xapikey xauthtoken
      xaccesstoken xcsrftoken xxsrftoken signature ssn creditcard cardnumber cvv
    ]).freeze

    SENSITIVE_KEY_FRAGMENTS = %w[
      token secret password passwd apikey authorization credential cookie
    ].freeze

    AUTH_SCHEME_PATTERN = %r{\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+/]+=*}i
    JWT_PATTERN = /\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/
    LOGISTER_KEY_PATTERN = /\blgst_[A-Za-z0-9_-]+/
    # A `name=value` pair at the start of a string or after a query, form, or
    # whitespace separator. Only values whose name is sensitive are replaced.
    USERINFO_PASSWORD_PATTERN = %r{\A([a-z][a-z0-9+.-]*://[^/?#@:]*):[^/?#@]*@}i
    QUERY_PAIR_PATTERN = /(\A|[?&;\s])([^=&;#?\s]+)=([^&;#\s]*)/
    # Single-quoted strings (with '' escapes and optional E/N/X/B prefixes),
    # dollar-quoted bodies, hex blobs, and numbers that are not part of an
    # identifier or a `$1` bind placeholder. Double quotes are left alone because
    # PostgreSQL and SQLite use them for identifiers.
    SQL_STRING_PATTERN = /(?<![A-Za-z0-9_])[EeNnXxBb]?'(?:[^'\\]|''|\\.)*'/
    SQL_DOLLAR_PATTERN = /\$([A-Za-z_][A-Za-z0-9_]*|)\$.*?\$\1\$/m
    SQL_NUMBER_PATTERN = /(?<![A-Za-z0-9_$.])-?(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)(?![A-Za-z0-9_])/

    module_function

    def normalize_key(key)
      key.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end

    def sensitive_key?(key, extra_keys = configured_keys)
      normalized = normalize_key(key)
      return false if normalized.empty?

      SENSITIVE_KEYS.include?(normalized) ||
        extra_keys.include?(normalized) ||
        SENSITIVE_KEY_FRAGMENTS.any? { |fragment| normalized.include?(fragment) }
    end

    # Scrubs credentials embedded in free text: auth schemes, JWTs, Logister
    # keys, and sensitive `name=value` pairs such as query parameters.
    def scrub_string(value, extra_keys = configured_keys)
      return value unless value.is_a?(String) && !value.empty?

      scrubbed = value.gsub(AUTH_SCHEME_PATTERN) { "#{Regexp.last_match(1)} #{REDACTED}" }
      scrubbed = scrubbed.gsub(JWT_PATTERN, REDACTED)
      scrubbed = scrubbed.gsub(LOGISTER_KEY_PATTERN, REDACTED)
      return scrubbed unless scrubbed.include?('=')

      scrubbed.gsub(QUERY_PAIR_PATTERN) do
        prefix, name, pair_value = Regexp.last_match.captures
        if !pair_value.empty? && sensitive_key?(decode_component(name), extra_keys)
          "#{prefix}#{name}=#{REDACTED}"
        else
          Regexp.last_match(0)
        end
      end
    end

    # Keeps scheme, host, and path; replaces credentials in userinfo and the
    # values of sensitive query parameters; drops the fragment.
    def redact_url(value, extra_keys = configured_keys)
      return value unless value.is_a?(String) && !value.empty?

      uri = URI.parse(value)
      uri.fragment = nil
      uri.query = redact_query(uri.query, extra_keys) if uri.query
      scrub_string(redact_userinfo(uri.to_s), extra_keys)
    rescue URI::Error, ArgumentError
      scrub_string(redact_userinfo(value.split('#', 2).first), extra_keys)
    end

    def redact_userinfo(url)
      url.sub(USERINFO_PASSWORD_PATTERN) { "#{Regexp.last_match(1)}:#{REDACTED}@" }
    end

    def redact_query(query, extra_keys = configured_keys)
      return query if query.nil? || query.empty?

      query.split('&', -1).map do |pair|
        name, separator, pair_value = pair.partition('=')
        if !separator.empty? && !pair_value.empty? && sensitive_key?(decode_component(name), extra_keys)
          "#{name}=#{REDACTED}"
        else
          pair
        end
      end.join('&')
    end

    def strip_sql_literals(sql)
      sql.to_s
         .gsub(SQL_DOLLAR_PATTERN, '?')
         .gsub(SQL_STRING_PATTERN, '?')
         .gsub(SQL_NUMBER_PATTERN, '?')
    end

    def configured_keys
      keys = Logister.configuration.redact_keys if Logister.respond_to?(:configuration)
      normalize_keys(keys)
    rescue StandardError
      Set.new
    end

    def normalize_keys(keys)
      Set.new(Array(keys).map { |key| normalize_key(key) }.reject(&:empty?))
    end

    def decode_component(name)
      URI.decode_www_form_component(name)
    rescue ArgumentError
      name
    end
  end
end
