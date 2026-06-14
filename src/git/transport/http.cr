require "http/client"
require "uri"

module Git
  # HTTP/HTTPS transport implemented with `::HTTP::Client`.
  # Implements the Git smart HTTP v1 protocol (stateless; one TCP connection per request).
  class Transport::HTTP < Transport::Base
    UPLOAD_PACK_ADVERTISEMENT = "application/x-git-upload-pack-advertisement"
    UPLOAD_PACK_REQUEST       = "application/x-git-upload-pack-request"
    UPLOAD_PACK_RESULT        = "application/x-git-upload-pack-result"

    def initialize(@url : Transport::RemoteURL, @credentials : Credentials? = nil)
    end

    def request(body : Bytes, &blk : IO ->) : Nil
      fetch_pack(body) { |io| blk.call(io) }
    end

    def handshake_io : IO
      info_refs_body
    end

    def stateless? : Bool
      true
    end

    # Performs `GET /info/refs?service=git-upload-pack` and returns the response body.
    # Raises `TransportError` on a non-2xx status or unexpected `Content-Type`.
    # Raises `AuthenticationError` on a 401 response.
    def info_refs_body : IO::Memory
      mem = IO::Memory.new
      client = make_client
      begin
        path = "#{@url.path.rstrip("/")}/info/refs?service=#{Protocol::SERVICE}"
        headers = ::HTTP::Headers{
          "User-Agent"   => Protocol::CapabilitySet::AGENT,
          "Git-Protocol" => Protocol::VERSION_2,
        }
        add_auth_header(headers)
        client.get(path, headers: headers) do |response|
          validate_response!(response, "info/refs", UPLOAD_PACK_ADVERTISEMENT)
          IO.copy(response.body_io, mem)
        end
      ensure
        client.close
      end
      mem.rewind
      mem
    end

    # Performs `POST /git-upload-pack` with *body* and yields the response body `IO` to the block.
    # Raises `TransportError` on a non-2xx status or unexpected `Content-Type`.
    # Raises `AuthenticationError` on a 401 response.
    def fetch_pack(body : Bytes, &outer_block : IO ->) : Nil
      client = make_client
      begin
        path = "#{@url.path.rstrip("/")}/#{Protocol::SERVICE}"
        headers = ::HTTP::Headers{
          "Content-Type" => UPLOAD_PACK_REQUEST,
          "Accept"       => UPLOAD_PACK_RESULT,
          "User-Agent"   => Protocol::CapabilitySet::AGENT,
          "Git-Protocol" => Protocol::VERSION_2,
        }
        add_auth_header(headers)
        client.post(path, headers: headers, body: body) do |response|
          validate_response!(response, Protocol::SERVICE, UPLOAD_PACK_RESULT)
          outer_block.call(response.body_io)
        end
      ensure
        client.close
      end
    end

    private def add_auth_header(headers : ::HTTP::Headers) : Nil
      if creds = @credentials
        headers["Authorization"] = creds.to_authorization_header
      end
    end

    private def make_client : ::HTTP::Client
      scheme = @url.scheme == Transport::RemoteURL::Scheme::HTTPS ? "https" : "http"
      if port = @url.port
        ::HTTP::Client.new(@url.host, port, tls: scheme == "https")
      else
        ::HTTP::Client.new(URI.parse("#{scheme}://#{@url.host}"))
      end
    end

    private def validate_response!(response : ::HTTP::Client::Response, endpoint : String, expected_ct : String) : Nil
      if response.status_code == 401
        raise AuthenticationError.new(
          "#{endpoint} requires authentication (HTTP 401). " \
          "Provide credentials via Git.basic or Git.bearer."
        )
      end
      unless response.status.success?
        raise TransportError.new("#{endpoint} request failed: #{response.status_code} #{response.status}")
      end
      ct = response.headers["Content-Type"]?
      unless ct && ct.starts_with?(expected_ct)
        raise TransportError.new("#{endpoint}: unexpected Content-Type #{ct.inspect}")
      end
    end
  end
end
