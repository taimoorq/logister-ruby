require 'test_helper'
require 'active_support/json'
require 'action_dispatch'
require 'stringio'

class JsonCompatibilityTest < Minitest::Test
  def test_supported_active_support_decodes_json_options
    assert_equal({ 'ok' => true }, ActiveSupport::JSON.decode('{"ok":true}'))
  end

  def test_rails_request_json_parameters
    body = '{"event":{"message":"test"}}'
    request = ActionDispatch::Request.new(
      'REQUEST_METHOD' => 'POST',
      'CONTENT_TYPE' => 'application/json',
      'CONTENT_LENGTH' => body.bytesize.to_s,
      'rack.input' => StringIO.new(body)
    )
    assert_equal 'test', request.request_parameters.fetch('event').fetch('message')
  end
end
