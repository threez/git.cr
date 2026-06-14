require "uri"

module Git
  module Transport
    # A parsed Git remote URL. Supports HTTPS, HTTP, SSH (`ssh://` scheme and SCP-style
    # `[user@]host:path`), and `file://` local paths.
    struct RemoteURL
      enum Scheme
        HTTPS
        HTTP
        SSH
        File
      end

      # Transport scheme (HTTPS, HTTP, SSH, or File).
      getter scheme : Scheme

      # Username from the URL, or `nil` when absent.
      getter user : String?

      # Hostname (e.g. `"github.com"`).
      getter host : String

      # Explicit port number, or `nil` when the scheme default applies.
      getter port : Int32?

      # Normalised path component (always starts with `/`).
      getter path : String

      # The original unparsed URL string passed to `parse`.
      getter original : String

      def initialize(@scheme, @host, @path, @original, @user = nil, @port = nil)
      end

      # Resolves a relative submodule URL (starting with `./` or `../`) against *parent*.
      # Absolute URLs are returned unchanged via `parse`.
      def self.resolve_relative(relative : String, parent : RemoteURL) : RemoteURL
        return parse(relative) unless relative.starts_with?("./") || relative.starts_with?("../")
        base = parent.path.chomp("/") + "/"
        joined = ::File.expand_path(relative, base)
        new(parent.scheme, parent.host, joined, joined, parent.user, parent.port)
      end

      # Parses *raw* into a `RemoteURL`. Raises `Error` on an unknown scheme.
      # SCP-style (`user@host:path`) is detected when there is no `://` and `:` appears after position 1.
      def self.parse(raw : String) : RemoteURL
        return parse_scp(raw) if scp_style?(raw)

        uri = URI.parse(raw)
        scheme = case uri.scheme
                 when "https" then Scheme::HTTPS
                 when "http"  then Scheme::HTTP
                 when "ssh"   then Scheme::SSH
                 when "file"  then Scheme::File
                 else              raise Error.new("Unsupported URL scheme: #{uri.scheme.inspect}")
                 end

        if scheme.file?
          return new(scheme, "", normalize_path(uri.path), raw)
        end

        host = uri.host.presence || raise Error.new("Missing host in URL: #{raw}")
        path = normalize_path(uri.path)

        new(scheme, host, path, raw, uri.user, uri.port)
      end

      # Returns true if the scheme is SSH.
      def ssh? : Bool
        scheme == Scheme::SSH
      end

      # Returns true if the scheme is HTTP or HTTPS.
      def http? : Bool
        scheme == Scheme::HTTP || scheme == Scheme::HTTPS
      end

      # Returns true if the scheme is `file://`.
      def file? : Bool
        scheme == Scheme::File
      end

      # Builds the argv to pass to Process.new for spawning an SSH connection.
      # The remote command (git-upload-pack) and quoted path are the final two args,
      # which SSH concatenates into a shell command on the remote host.
      def to_ssh_command : Array(String)
        argv = ["ssh"]
        argv << "-p" << @port.to_s if @port
        argv << (@user ? "#{@user}@#{@host}" : @host)
        argv << Protocol::SERVICE
        argv << quote_shell_path(@path)
        argv
      end

      def to_s(io : IO) : Nil
        io << @original
      end

      private def self.scp_style?(raw : String) : Bool
        return false if raw.includes?("://")
        colon_idx = raw.index(':')
        return false unless colon_idx
        # Ensure the part before : doesn't look like a drive letter (e.g. C:\path)
        colon_idx > 1
      end

      private def self.parse_scp(raw : String) : RemoteURL
        colon_idx = raw.index(':') || raise Error.new("Invalid SCP URL: #{raw}")
        left = raw[0, colon_idx]
        right = raw[colon_idx + 1..]

        user, host = if at_idx = left.rindex('@')
                       {left[0, at_idx], left[at_idx + 1..]}
                     else
                       {nil, left}
                     end

        path = right.starts_with?('/') ? right : "/#{right}"
        new(Scheme::SSH, host, path, raw, user)
      end

      private def self.normalize_path(raw : String) : String
        path = raw.empty? ? "/" : raw
        path.starts_with?("/") ? path : "/#{path}"
      end

      private def quote_shell_path(path : String) : String
        "'" + path.gsub("'", "'\\''") + "'"
      end
    end
  end
end
