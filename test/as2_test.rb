require 'test_helper'

describe As2 do
  describe '.generate_message_id' do
    it 'creates a message id string based on given server_info' do
      server_info = build_server_info('BOB', credentials: 'server')

      message_ids = []
      5.times do
        message_id = As2.generate_message_id(server_info)
        message_ids << message_id
        assert message_id.match(/^\<#{server_info.name}-\d{8}-\d{6}-[a-f0-9\-]{36}@#{server_info.domain}\>$/), "'#{message_id}' does not match expected pattern."
      end

      assert_equal 5, message_ids.uniq.size
    end
  end

  describe '.base64_encode' do
    it 'can encode according to RFC-2045'
    it 'can encode according to RFC-4648'
    it 'raises if the given encoding scheme is not recognized'
    it 'defaults to RFC-4648 for backwards-compatibility'
  end

  describe '.canonicalize_line_endings' do
    it 'replaces \n with \r\n'
    it 'does not alter existing \r\n sequences'
  end

  describe '.choose_mic_algorithm' do
    it 'returns nil if no algorithm is found' do
      assert_nil As2.choose_mic_algorithm(nil)
      assert_nil As2.choose_mic_algorithm('')
    end

    it 'selects best mic algorithm from HTTP header' do
      header_value = 'signed-receipt-protocol=optional, pkcs7-signature; signed-receipt-micalg=optional, SHA256'
      assert_equal 'SHA256', As2.choose_mic_algorithm(header_value)
    end

    it 'returns nil if no options are valid' do
      header_value = 'signed-receipt-protocol=optional, pkcs7-signature; signed-receipt-micalg=optional, xxx, yyy'
      assert_nil As2.choose_mic_algorithm(header_value)
    end

    it 'returns first acceptable algo if client specifies multiple valid options' do
      header_value = 'signed-receipt-protocol=optional, pkcs7-signature; signed-receipt-micalg=optional, invalid, sha1, md5'
      assert_equal 'sha1', As2.choose_mic_algorithm(header_value)

      header_value = 'signed-receipt-protocol=optional, pkcs7-signature; signed-receipt-micalg=optional, invalid, md5, sha1'
      assert_equal 'md5', As2.choose_mic_algorithm(header_value)
    end
  end

  describe '.quoted_system_identifier' do
    it 'returns the string unchanged if it does not contain a space' do
      assert_equal 'A', As2.quoted_system_identifier('A')
    end

    it 'surrounds name with double-quotes if it contains a space' do
      assert_equal '"A A"', As2.quoted_system_identifier('A A')
    end

    it 'returns non-string inputs unchanged' do
      assert_nil As2.quoted_system_identifier(nil)
      assert_equal 1, As2.quoted_system_identifier(1)
      assert_equal true, As2.quoted_system_identifier(true)
      assert_equal :symbol, As2.quoted_system_identifier(:symbol)
      assert_equal({}, As2.quoted_system_identifier({}))
    end

    it 'does not re-quote a string which is already quoted' do
      assert_equal '"A A"', As2.quoted_system_identifier('"A A"')
    end
  end

  describe '.unquoted_system_identifier' do
    it 'removes leading/trailing double-quotes if present' do
      assert_equal 'AA', As2.unquoted_system_identifier('"AA"')
      assert_equal 'A A', As2.unquoted_system_identifier('"A A"')
    end

    it 'does nothing to a string which do not contain leading/trailing double-quotes' do
      assert_equal 'AA', As2.unquoted_system_identifier('AA')
      assert_equal 'A A', As2.unquoted_system_identifier('A A')
    end

    it 'unescapes interior double-quotes' do
      assert_equal 'A"A', As2.unquoted_system_identifier('"A\"A"')
    end

    it 'returns non-string inputs unchanged' do
      assert_nil As2.unquoted_system_identifier(nil)
      assert_equal 1, As2.unquoted_system_identifier(1)
      assert_equal true, As2.unquoted_system_identifier(true)
      assert_equal :symbol, As2.unquoted_system_identifier(:symbol)
      assert_equal({}, As2.unquoted_system_identifier({}))
    end
  end
end
