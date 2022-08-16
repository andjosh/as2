require 'test_helper'
require 'base64'

describe As2::Message do
  before do
    @server_key = private_key('test/certificates/server.key')
    @server_crt = public_key('test/certificates/server.crt')
    @client_crt = public_key('test/certificates/client.crt')

    @encrypted_message = File.read('test/fixtures/hello_world_2.pkcs7')
    @correct_cleartext = "hello world 2\n"

    @message = As2::Message.new(@encrypted_message, @server_key, @server_crt)
  end

  describe '.choose_attachment' do
    it 'returns nil if no parts are given' do
      assert_nil As2::Message.choose_attachment(nil)
      assert_nil As2::Message.choose_attachment([])
    end

    it 'chooses an EDI part if available' do
      decrypted_message = <<~EOF
      Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha1; boundary="1660166778989-boundary"

      --1660166778989-boundary
      Content-Type: application/octet-stream

      This is text content.


      --1660166778989-boundary
      Content-Type: application/edi-x12

      ISA*TOTALLY*LEGAL*EDI~

      --1660166778989-boundary
      Content-Type: application/pkcs7-signature

      blah blah blah blah
      --1660166778989-boundary
      EOF

      mail = Mail.new(decrypted_message)
      chosen = As2::Message.choose_attachment(mail.parts)

      assert_equal "ISA*TOTALLY*LEGAL*EDI~\n", chosen.body.to_s

      ## reversing order of EDI & text parts, to make sure we have sorting right.
      decrypted_message = <<~EOF
      Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha1; boundary="1660166778989-boundary"

      --1660166778989-boundary
      Content-Type: application/edi-x12

      ISA*TOTALLY*LEGAL*EDI~

      --1660166778989-boundary
      Content-Type: application/octet-stream

      This is text content.


      --1660166778989-boundary
      Content-Type: application/pkcs7-signature

      blah blah blah blah
      --1660166778989-boundary
      EOF

      mail = Mail.new(decrypted_message)
      chosen = As2::Message.choose_attachment(mail.parts)

      assert_equal "ISA*TOTALLY*LEGAL*EDI~\n", chosen.body.to_s
    end

    it 'chooses a non-EDI part if no EDI parts are available' do
      decrypted_message = <<~EOF
      Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha1; boundary="1660166778989-boundary"

      --1660166778989-boundary
      Content-Type: application/octet-stream

      This is text content.


      --1660166778989-boundary
      Content-Type: application/pkcs7-signature

      blah blah blah blah
      --1660166778989-boundary
      EOF

      mail = Mail.new(decrypted_message)
      chosen = As2::Message.choose_attachment(mail.parts)

      assert_equal "This is text content.\n\n", chosen.body.to_s
    end

    it 'returns nil if no non-signature parts are available' do
      decrypted_message = <<~EOF
      Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha1; boundary="1660166778989-boundary"

      --1660166778989-boundary
      Content-Type: application/pkcs7-signature

      blah blah blah blah
      --1660166778989-boundary
      EOF

      mail = Mail.new(decrypted_message)
      chosen = As2::Message.choose_attachment(mail.parts)

      assert_nil chosen
    end

    it 'skips x-pkcs7-signature also' do
      decrypted_message = <<~EOF
      Content-Type: multipart/signed; protocol="application/x-pkcs7-signature"; micalg="sha-256"; \tboundary="----855604ACC1530DC371EC9487F598CF78"

      ------855604ACC1530DC371EC9487F598CF78
      Content-Type: application/octet-stream

      This is text content.
      ------855604ACC1530DC371EC9487F598CF78
      Content-Type: application/x-pkcs7-signature; name="smime.p7s"
      Content-Transfer-Encoding: base64
      Content-Disposition: attachment; filename="smime.p7s"

      blah blah blah blah
      ------855604ACC1530DC371EC9487F598CF78--
      EOF

      mail = Mail.new(decrypted_message)
      chosen = As2::Message.choose_attachment(mail.parts)

      assert_equal "This is text content.", chosen.body.to_s
    end
  end

  describe '#decrypted_message' do
    it 'returns a decrypted smime message' do
      decrypted = @message.decrypted_message
      assert_equal String, decrypted.class

      mail = Mail.new(decrypted)
      assert_equal 2, mail.parts.size
      assert_equal mail.parts.map(&:content_type), ['application/edi-consent', 'application/pkcs7-signature; name=smime.p7s; smime-type=signed-data']
    end
  end

  describe '#valid_signature?' do
    it 'is successful when message content contains trailing newline'
    it 'is successful when message content does not contain trailing newline'

    it 'is true when message is signed properly' do
      assert @message.valid_signature?(@client_crt), "Invalid signature"
    end

    it 'is false when message was not signed by given cert' do
      assert !@message.valid_signature?(@server_crt), "Signature should be invalid."
      assert_equal "signer certificate not found", @message.verification_error
    end

    it 'is false when signature does not match content' do
      hacked_payload = 'h4xx0rd'
      encrypted = OpenSSL::PKCS7.new(File.read('test/fixtures/hello_world_2.pkcs7'))
      decrypted = encrypted.decrypt @server_key, @server_crt

      # replace the correct (base64-encoded) payload with our own and re-encrypt
      hacked_cleartext = decrypted.gsub(Base64.strict_encode64(@correct_cleartext), Base64.strict_encode64(hacked_payload))
      cipher = OpenSSL::Cipher::AES.new("128-CBC")
      hacked_encrypted = OpenSSL::PKCS7.encrypt([@server_crt], hacked_cleartext, cipher)

      # build messge with modified payload
      message = As2::Message.new(hacked_encrypted.to_der, @server_key, @server_crt)

      assert !message.valid_signature?(@client_crt)
      assert_equal "digest failure", message.verification_error
      assert_equal hacked_payload, message.attachment.body.to_s
    end
  end

  describe '#mic' do
    it 'returns a message integrity check value' do
      assert_equal @message.mic, "7S8fpWpx+ASDj0sCAIfS64Q+sm0ezIpDLhPs9wIEy8I="
    end
  end

  describe '#mic_algorithm' do
    it 'returns a string describing the algorithm used for MIC calculation' do
      assert_equal @message.mic_algorithm, 'sha256'
    end
  end

  describe '#attachment' do
    it 'provides the inbound message as a Mail::Part' do
      attachment = @message.attachment
      assert_equal attachment.class, Mail::Part
      assert_equal attachment.content_type, 'application/edi-consent'
      assert_equal @correct_cleartext, attachment.body.decoded
      assert_equal "hello_world_2.txt", attachment.filename
    end

    it 'chooses a non-edi part if no edi parts are available' do
      encrypted_message = File.read('test/fixtures/non_edi_content.pkcs7')
      correct_cleartext = "this is a message\n\n"

      message = As2::Message.new(encrypted_message, @server_key, @server_crt)
      attachment = message.attachment

      assert_equal attachment.class, Mail::Part
      assert_equal attachment.content_type, 'application/octet-stream'
      assert_equal correct_cleartext, attachment.body.to_s
      assert_equal nil, attachment.filename
    end
  end
end
