require 'test_helper'

describe As2::Client do
  it 'accepts partner info as a config param'
  it 'searches global config if partner is a string'
  it 'accepts server_info as a config param'
  it 'uses global server config if server_info is nil'

  # these are really 'dogfood' tests using both As2::Client and As2::Server.
  describe '#send_file' do
    before do
      # scenario: Alice is sending a message to Bob.
      @alice_partner = build_partner('ALICE', credentials: 'client')
      @alice_server_info = build_server_info('ALICE', credentials: 'client')

      @bob_partner = build_partner('BOB', credentials: 'server')
      @bob_server_info = build_server_info('BOB', credentials: 'server')

      @alice_client = As2::Client.new(@bob_partner, server_info: @alice_server_info)

      stub_request(:post, @bob_partner.url).to_return do |request|
        # do all the HTTP things that rack would do during a real request
        headers = request.headers.transform_keys {|k| "HTTP_#{k.upcase}".gsub('-', '_') }
        body = Base64.decode64(request.body)
        env = Rack::MockRequest.env_for(request.uri.path, headers.merge(input: body))

        # then hand off the content to @bob_server (which must be defined by the actual tests below)
        status, headers, body = @bob_server.call(env)
        {
          status: status,
          headers: headers,
          body: body.first
        }
      end
    end

    describe 'when file_content is given' do
      it 'sends the given file content' do
        file_name_received_by_bob = nil
        file_content_received_by_bob = nil

        @bob_server = As2::Server.new(server_info: @bob_server_info, partner: @alice_partner) do |file_name, body|
                        file_name_received_by_bob = file_name
                        file_content_received_by_bob = body.to_s
                      end

        file_name = 'data.txt'

        result = @alice_client.send_file(file_name, content: File.read('test/fixtures/message.txt'))

        assert_equal file_name, file_name_received_by_bob
        assert_equal File.read('test/fixtures/message.txt'), file_content_received_by_bob
      end
    end

    describe 'when file_content is nil' do
      it 'reads content from file_name' do
        file_name_received_by_bob = nil
        file_content_received_by_bob = nil

        @bob_server = As2::Server.new(server_info: @bob_server_info, partner: @alice_partner) do |file_name, body|
                        file_name_received_by_bob = file_name
                        file_content_received_by_bob = body.to_s
                      end

        file_path = 'test/fixtures/message.txt'
        dir_name = File.dirname(file_path)
        file_name = File.basename(file_path)

        Dir.chdir(dir_name) do
          result = @alice_client.send_file(file_name)

          assert_equal file_name, file_name_received_by_bob
          assert_equal File.read(file_name), file_content_received_by_bob
        end
      end
    end

    describe 'non-ASCII content' do
      # not totally smooth due to character encoding. the bytes make it, but it's not a totally transparent process.
      # lower-priority issue since EDI is all ASCII, but worth being aware of & fixing at some point.
      # maybe Server could accept a parameter which tells us which character encoding to use?
      it 'is not mangled too horribly' do
        file_name_received_by_bob = nil
        file_content_received_by_bob = nil

        @bob_server = As2::Server.new(server_info: @bob_server_info, partner: @alice_partner) do |file_name, body|
                        file_name_received_by_bob = file_name
                        file_content_received_by_bob = body.to_s
                      end

        file_name = 'data.txt'

        result = @alice_client.send_file(file_name, content: File.read('test/fixtures/multibyte.txt'))

        assert_equal file_name, file_name_received_by_bob
        assert_equal File.read('test/fixtures/multibyte.txt', encoding: 'ASCII-8BIT'), file_content_received_by_bob
      end
    end
  end
end
