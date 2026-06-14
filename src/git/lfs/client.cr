require "http/client"
require "json"
require "uri"

module Git
  module LFS
    # Raised when an LFS batch request or object download fails.
    class LFSError < Git::Error; end

    # Fetches actual LFS file content from an LFS-enabled remote server.
    class Client
      LFS_CONTENT_TYPE = "application/vnd.git-lfs+json"

      @credentials : Transport::Credentials?
      @http_factory : (String, Int32?, Bool -> HTTP::Client)?

      # Constructs a client from a parsed remote URL, inferring TLS from the scheme.
      def initialize(remote : Transport::RemoteURL, credentials : Transport::Credentials? = nil,
                     http_factory : (String, Int32?, Bool -> HTTP::Client)? = nil)
        @tls = remote.original.starts_with?("https")
        @host = remote.host
        @port = remote.port
        @lfs_path = "#{remote.path.chomp("/")}/info/lfs"
        @credentials = credentials
        @http_factory = http_factory
      end

      # Constructs a client from explicit connection parameters (used for SSH-derived endpoints).
      def initialize(*, tls : Bool, host : String, port : Int32?, path : String,
                     credentials : Transport::Credentials? = nil,
                     http_factory : (String, Int32?, Bool -> HTTP::Client)? = nil)
        @tls = tls
        @host = host
        @port = port
        @lfs_path = "#{path.chomp("/")}/info/lfs"
        @credentials = credentials
        @http_factory = http_factory
      end

      # Derives an HTTPS LFS endpoint from an SSH remote's host and path.
      def self.for_ssh(remote : Transport::RemoteURL, credentials : Transport::Credentials? = nil) : Client
        new(tls: true, host: remote.host, port: nil, path: remote.path, credentials: credentials)
      end

      # Reads `.lfsconfig` from *work_dir* and returns a Client if a valid LFS url is found.
      def self.from_lfs_config?(work_dir : String, credentials : Transport::Credentials? = nil, fs : FileSystem = FileSystem::Local.new) : Client?
        config_path = File.join(work_dir, ".lfsconfig")
        return nil unless fs.file?(config_path)
        config = Repository::Config.parse(fs.read(config_path))
        url = config.sections["lfs"]?.try(&.["url"]?) || return nil
        remote = Git.remote(url)
        return nil unless remote.http?
        new(remote, credentials)
      end

      # Issues a single batch request for all *pointers* and downloads their content.
      # Returns a map of sha256 oid → file bytes. Skips objects the server cannot serve.
      def fetch_batch(pointers : Array(Pointer)) : Hash(String, Bytes)
        return Hash(String, Bytes).new if pointers.empty?

        response = batch_request(pointers)
        if response.status_code == 401
          raise AuthenticationError.new(
            "LFS batch request requires authentication (HTTP 401). " \
            "Provide credentials via Git.basic or Git.bearer."
          )
        end
        raise LFSError.new("LFS batch request failed: #{response.status_code}") unless response.success?

        parse_batch_response(response.body)
      end

      private def batch_request(pointers : Array(Pointer)) : HTTP::Client::Response
        objects = pointers.map { |ptr| %({"oid":"#{ptr.oid}","size":#{ptr.size}}) }.join(",")
        body = %({"operation":"download","transfers":["basic"],"objects":[#{objects}]})
        headers = HTTP::Headers{
          "Content-Type" => LFS_CONTENT_TYPE,
          "Accept"       => LFS_CONTENT_TYPE,
        }
        if creds = @credentials
          headers["Authorization"] = creds.to_authorization_header
        end
        make_client.post(
          "#{@lfs_path}/objects/batch",
          headers: headers,
          body: body,
        )
      end

      private def parse_batch_response(body : String) : Hash(String, Bytes)
        result = Hash(String, Bytes).new
        json = JSON.parse(body)
        json["objects"].as_a.each do |obj|
          oid = obj["oid"]?.try(&.as_s?) || next
          download = obj.dig?("actions", "download") || next
          href = download["href"]?.try(&.as_s?) || next
          extra_headers = parse_response_headers(download["header"]?)
          result[oid] = download_object(href, extra_headers)
        end
        result
      rescue JSON::ParseException
        raise LFSError.new("LFS batch response is not valid JSON")
      rescue TypeCastError
        raise LFSError.new("Unexpected LFS batch response shape")
      end

      private def parse_response_headers(json_val : JSON::Any?) : Hash(String, String)?
        return nil unless json_val
        hash = json_val.as_h? || return nil
        headers = {} of String => String
        hash.each { |key, val| headers[key] = val.as_s? || "" }
        headers.empty? ? nil : headers
      end

      private def download_object(href : String, extra_headers : Hash(String, String)?) : Bytes
        headers = HTTP::Headers.new
        extra_headers.try(&.each { |key, val| headers[key] = val })
        response = HTTP::Client.get(href, headers: headers)
        raise LFSError.new("LFS download failed (#{response.status_code}): #{href}") unless response.success?
        response.body.to_slice
      end

      private def make_client : HTTP::Client
        if factory = @http_factory
          return factory.call(@host, @port, @tls)
        end
        if port = @port
          HTTP::Client.new(@host, port, tls: @tls)
        else
          scheme = @tls ? "https" : "http"
          HTTP::Client.new(URI.parse("#{scheme}://#{@host}"))
        end
      end
    end
  end
end
