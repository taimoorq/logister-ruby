require_relative "test_helper"
require "json"

class RedactionTest < Minitest::Test
  REDACTED = Logister::Redaction::REDACTED

  def test_exact_and_fragment_key_rules_match_the_shared_spec
    %w[
      password passwd pwd secret token api_key apiKey API-KEY authorization Proxy-Authorization
      cookie Set-Cookie session_token sessionKey credential credentials private_key client_secret
      access_token refresh_token id_token auth_token X-Api-Key x_auth_token X-Access-Token
      X-CSRF-Token x-xsrf-token signature ssn credit_card cardNumber CVV
      user_password githubToken client-secret-value my_apikey_2 AuthorizationHeader db_credential
      session_cookie_name
    ].each do |key|
      assert Logister::Redaction.sensitive_key?(key, Set.new), "expected #{key} to be sensitive"
    end

    %w[id email name author session session_id user_agent request_id signed_at pw ssn_last4 card].each do |key|
      refute Logister::Redaction.sensitive_key?(key, Set.new), "expected #{key} not to be sensitive"
    end
  end

  def test_configured_keys_are_normalized_and_matched_exactly
    Logister.configuration.redact_keys = ["Internal-Id", :tenant_ref]

    assert Logister::Redaction.sensitive_key?("internal_id")
    assert Logister::Redaction.sensitive_key?("TENANT-REF")
    refute Logister::Redaction.sensitive_key?("internal_identifier")
  end

  def test_string_values_are_scrubbed_for_credentials
    input = "auth=Bearer abc.DEF-123 basic Zm9vOmJhcg== jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln key lgst_live_ABC123 ok"
    expected = "auth=Bearer #{REDACTED} basic #{REDACTED} jwt #{REDACTED} key #{REDACTED} ok"

    assert_equal expected, Logister::Redaction.scrub_string(input, Set.new)
    assert_equal "GET /cb?code=1&access_token=#{REDACTED}&page=2",
                 Logister::Redaction.scrub_string("GET /cb?code=1&access_token=xyz&page=2", Set.new)
    assert_equal "login failed password=#{REDACTED}", Logister::Redaction.scrub_string("login failed password=hunter2", Set.new)
  end

  def test_urls_keep_scheme_host_and_path_but_redact_sensitive_query_values
    url = "https://user:pa55@example.com/cb/path?token=abc&code=1&api%5Fkey=k&empty=&x=eyJa.eyJb.c#frag"

    assert_equal "https://user:#{REDACTED}@example.com/cb/path?token=#{REDACTED}&code=1&api%5Fkey=#{REDACTED}&empty=&x=#{REDACTED}",
                 Logister::Redaction.redact_url(url, Set.new)
    assert_equal "/relative?password=#{REDACTED}", Logister::Redaction.redact_url("/relative?password=p", Set.new)
    assert_equal "not a url password=#{REDACTED}", Logister::Redaction.redact_url("not a url password=p", Set.new)
    assert_nil Logister::Redaction.redact_url(nil, Set.new)
  end

  def test_sql_literals_are_stripped
    sql = %q(SELECT "users".* FROM "users" WHERE "users"."email" = 'a@b.co' AND reset_token = E'it''s' AND id IN (1, 2.5, -3) AND t1.col = $1 AND body = $$secret$$ AND blob = x'DEADBEEF' LIMIT 10)

    assert_equal %q(SELECT "users".* FROM "users" WHERE "users"."email" = ? AND reset_token = ? AND id IN (?, ?, ?) AND t1.col = $1 AND body = ? AND blob = ? LIMIT ?),
                 Logister::Redaction.strip_sql_literals(sql)
  end

  def test_sanitizer_redacts_context_tree_but_not_envelope_fields
    payload = {
      uuid: "event-uuid",
      event_type: "error",
      message: "failed with Bearer secret-token",
      context: {
        trace_id: "a" * 32,
        request_id: "req-1",
        password: "hunter2",
        headers: { "Cookie" => "sid=1", "Accept" => "text/html" },
        breadcrumbs: [{ category: "http", data: { "api_key" => "k", url: "https://x.test/?token=t" } }],
        job: { arguments: [{ "card_number" => "4111", "note" => "eyJa.eyJb.c" }] },
        tags: { secret_flag: true, region: "eu" },
        span: { attributes: { "db.password" => "p" } },
        log: { fields: { refresh_token: "r", status: 200 } }
      }
    }

    sanitized = Logister::EventSanitizer.call(payload, extra_keys: Set.new)
    context = sanitized.fetch(:context)

    assert_equal "event-uuid", sanitized[:uuid]
    assert_equal "failed with Bearer #{REDACTED}", sanitized[:message]
    assert_equal "a" * 32, context["trace_id"]
    assert_equal "req-1", context["request_id"]
    assert_equal REDACTED, context["password"]
    assert_equal({ "Cookie" => REDACTED, "Accept" => "text/html" }, context["headers"])
    assert_equal({ "api_key" => REDACTED, "url" => "https://x.test/?token=#{REDACTED}" }, context["breadcrumbs"][0]["data"])
    assert_equal [{ "card_number" => REDACTED, "note" => REDACTED }], context.dig("job", "arguments")
    assert_equal({ "secret_flag" => REDACTED, "region" => "eu" }, context["tags"])
    assert_equal REDACTED, context.dig("span", "attributes", "db.password")
    assert_equal({ "refresh_token" => REDACTED, "status" => 200 }, context.dig("log", "fields"))
    refute_includes JSON.generate(sanitized), "hunter2"
  end

  def test_sanitizer_produces_json_safe_bounded_values
    deep = (1..20).reduce({ leaf: 1 }) { |acc, index| { "level#{index}" => acc } }
    record = Struct.new(:name).new("widget")
    as_json_object = Object.new
    def as_json_object.as_json(*) = { "secret" => "s", "visible" => "v" }

    payload = {
      uuid: "u",
      message: "bad \xFF byte".dup.force_encoding("UTF-8"),
      context: {
        nan: Float::NAN,
        huge: "x" * 40_000,
        deep: deep,
        list: (1..500).to_a,
        struct: record,
        object: as_json_object,
        time: Time.utc(2026, 10, 23),
        binary: "\xFF\xFE".b
      }
    }

    sanitized = Logister::EventSanitizer.call(payload, extra_keys: Set.new)
    context = sanitized[:context]

    JSON.generate(sanitized)
    assert sanitized[:message].valid_encoding?
    assert_equal "NaN", context["nan"]
    assert_operator context["huge"].bytesize, :<, 17_000
    assert_equal 100, context["list"].length
    assert_equal({ "name" => "widget" }, context["struct"])
    assert_equal({ "secret" => REDACTED, "visible" => "v" }, context["object"])
    assert_equal "2026-10-23T00:00:00Z", context["time"]
    assert context["binary"].valid_encoding?
    assert_equal true, context[Logister::EventSanitizer::TRUNCATION_MARKER_KEY]
    depth = 0
    node = context["deep"]
    while node.is_a?(Hash)
      depth += 1
      node = node.values.first
    end
    assert_equal Logister::EventSanitizer::TRUNCATED, node
    assert_operator depth, :<=, 10
  end

  def test_key_budget_keeps_exception_context_before_breadcrumbs
    breadcrumbs = 200.times.map { |index| { category: "c", message: "m#{index}", data: { a: 1, b: 2 } } }
    payload = { uuid: "u", context: { breadcrumbs: breadcrumbs, exception: { class: "Boom", message: "x" } } }

    context = Logister::EventSanitizer.call(payload, extra_keys: Set.new)[:context]

    assert_equal "Boom", context.dig("exception", "class")
    assert_equal true, context[Logister::EventSanitizer::TRUNCATION_MARKER_KEY]
    key_count = lambda do |value|
      case value
      when Hash then value.size + value.values.sum { |nested| key_count.call(nested) }
      when Array then value.sum { |nested| key_count.call(nested) }
      else 0
      end
    end
    assert_operator key_count.call(context), :<=, 512
  end
end
