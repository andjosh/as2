require 'rack'
require 'logger'
require 'stringio'
require 'as2/mime_generator'
require 'as2/message'

module As2
  class Server
    attr_accessor :logger

    # @param [As2::Config::ServerInfo] server_info Config used for naming of this
    #   server and key/certificate selection. If omitted, the main As2::Config.server_info is used.
    # @param [As2::Config::Partner] partner Which partner to receive messages from.
    #   If omitted, the partner is determined by incoming HTTP headers.
    # @param [Proc] on_signature_failure A proc which will be called if signature verification fails.
    # @param [Proc] block A proc which will be called with file_name and file content.
    def initialize(server_info: nil, partner: nil, on_signature_failure: nil, &block)
      @block = block
      @server_info = server_info || Config.server_info
      @partner = partner
      @signature_failure_handler = on_signature_failure
    end

    def call(env)
      if env['HTTP_AS2_TO'] != @server_info.name
        return send_error(env, "Invalid destination name #{env['HTTP_AS2_TO']}")
      end

      partner = @partner || Config.partners[env['HTTP_AS2_FROM']]

      if !partner || env['HTTP_AS2_FROM'] != partner.name
        return send_error(env, "Invalid partner name #{env['HTTP_AS2_FROM']}")
      end

      request = Rack::Request.new(env)
      message = Message.new(request.body.read, @server_info.pkey, @server_info.certificate)

      unless message.valid_signature?(partner.certificate)
        if @signature_failure_handler
          @signature_failure_handler.call({
            env: env,
            smime_string: message.decrypted_message,
            verification_error: message.verification_error
          })
        else
          raise "Could not verify signature"
        end
      end

      if @block
        begin
          @block.call message.attachment.filename, message.attachment.body
        rescue Exception => e
          return send_error(env, e.message)
        end
      end

      send_mdn(env, message.mic, message.mic_algorithm)
    end

    def send_mdn(env, mic, mic_algorithm, failed = nil)
      # rules for MDN construction are covered in
      # https://datatracker.ietf.org/doc/html/rfc4130#section-7.4.2

      options = {
        'Reporting-UA' => @server_info.name,
        'Original-Recipient' => "rfc822; #{@server_info.name}",
        'Final-Recipient' => "rfc822; #{@server_info.name}",
        'Original-Message-ID' => env['HTTP_MESSAGE_ID']
      }
      if failed
        options['Disposition'] = 'automatic-action/MDN-sent-automatically; failed'
        options['Failure'] = failed
        text_body = "There was an error with the AS2 transmission.\r\n\r\n#{failed}"
      else
        options['Disposition'] = 'automatic-action/MDN-sent-automatically; processed'
        text_body = "The AS2 message has been received successfully"
      end
      options['Received-Content-MIC'] = "#{mic}, #{mic_algorithm}" if mic

      report = MimeGenerator::Part.new
      report['Content-Type'] = 'multipart/report; report-type=disposition-notification'

      text_part = MimeGenerator::Part.new
      text_part['Content-Type'] = 'text/plain'
      text_part['Content-Transfer-Encoding'] = '7bit'
      text_part.body = text_body
      report.add_part text_part

      notification_part = MimeGenerator::Part.new
      notification_part['Content-Type'] = 'message/disposition-notification'
      notification_part['Content-Transfer-Encoding'] = '7bit'
      notification_part.body = options.map{|n, v| "#{n}: #{v}"}.join("\r\n")
      report.add_part notification_part

      msg_out = StringIO.new
      report.write msg_out
      mdn_text = msg_out.string

      headers, body = format_mdn_v1(mdn_text,
                        mic_algorithm: mic_algorithm,
                        as2_to: env['HTTP_AS2_FROM']
                      )

      [200, headers, ["\r\n" + body]]
    end

    def format_mdn_v1(mdn_text, mic_algorithm:, as2_to:)
      pkcs7 = OpenSSL::PKCS7.sign @server_info.certificate, @server_info.pkey, mdn_text
      pkcs7.detached = true

      # PEM (base64-encoded) signature
      bare_pem_signature = pkcs7.to_pem
      # without the '-----BEGIN PKCS7-----' / '-----END PKCS7-----' delimiters
      bare_pem_signature.gsub!(/^-----[^\n]+\n/, '')
      # and with canonical \r\n line endings
      bare_pem_signature.gsub!(/(?<!\r)\n/, "\r\n")

      # > A good strategy is to choose a boundary that includes
      # > a character sequence such as "=_" which can never appear in a
      # > quoted-printable body.
      #
      # https://www.rfc-editor.org/rfc/rfc2045#page-21
      header_boundary = "----=_#{SecureRandom.hex(16).upcase}"
      body_boundary = "--#{header_boundary}"

      body = body_boundary + "\r\n"
      # this is the MDN report, with text/plain and message/disposition-notification parts
      body += mdn_text + "\r\n"
      body += body_boundary + "\r\n"
      # this is the signature generated over that report
      body += "Content-Type: application/pkcs7-signature; name=\"smime.p7s\"\r\n"
      body += "Content-Transfer-Encoding: base64\r\n"
      body += "Content-Disposition: attachment; filename=\"smime.p7s\"\r\n"
      body += "\r\n"
      body += bare_pem_signature
      body += body_boundary + "--\r\n"

      headers = {}
      headers['Content-Type'] = "multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=\"#{mic_algorithm}\"; boundary=\"#{header_boundary}\""
      headers['MIME-Version'] = '1.0'
      headers['Message-ID'] = As2.generate_message_id(@server_info)
      headers['AS2-From'] = @server_info.name
      headers['AS2-To'] = as2_to
      headers['AS2-Version'] = '1.0'
      headers['Connection'] = 'close'

      [headers, body]
    end

    private

    def logger(env)
      @logger ||= Logger.new env['rack.errors']
    end

    def send_error(env, msg)
      logger(env).error msg
      send_mdn env, nil, 'sha1', msg
    end
  end
end
