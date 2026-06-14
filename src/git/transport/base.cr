module Git
  # Namespace and factory for all Git transport implementations.
  # Use `Transport.for(url)` to obtain the correct subclass for a given URL.
  # Concrete implementations: `Transport::HTTP`, `Transport::SSH`, `Transport::File`.
  module Transport
    # Returns the appropriate `Transport::Base` subclass for *url*, passing *credentials*
    # to HTTP transports. SSH and file:// transports ignore credentials (they use
    # ssh-agent and local filesystem access respectively).
    # Raises `Error` for unsupported URL schemes.
    def self.for(url : RemoteURL, credentials : Credentials? = nil) : Base
      case url.scheme
      when RemoteURL::Scheme::HTTPS, RemoteURL::Scheme::HTTP
        HTTP.new(url, credentials)
      when RemoteURL::Scheme::SSH
        SSH.new(url)
      when RemoteURL::Scheme::File
        File.new(url)
      else
        raise Error.new("Unsupported transport scheme: #{url.scheme}")
      end
    end

    # Abstract base class for all Git transport implementations.
    abstract class Base
      # Opens the connection to the remote. No-op for stateless transports (HTTP);
      # spawns the subprocess for pipe transports (SSH, file://).
      def open : Nil
      end

      # Override point for connection teardown.
      # May raise `TransportError` if the server process exits non-zero.
      # No-op for stateless transports; concrete implementations override.
      def close : Nil
      end

      # Issues one command exchange: writes *body* to the server and yields the response IO.
      # For HTTP each call is an independent stateless POST; for pipe it writes to stdin and
      # yields stdout (shared across all calls on the same open transport).
      abstract def request(body : Bytes, & : IO ->) : Nil

      # Returns the IO carrying the server's initial version advertisement.
      # Called by `Negotiator` immediately after `open`.
      # For HTTP: performs GET /info/refs; may raise `TransportError` or `AuthenticationError`.
      # For pipe transports: returns the already-open stdout, no network I/O.
      abstract def handshake_io : IO

      # True for stateless transports (HTTP); false for stateful pipe transports.
      # Controls how `Negotiator` parses the ref advertisement and which `Session` it creates.
      abstract def stateless? : Bool

      # True for transports whose LFS endpoint is discovered from the checked-out .lfsconfig.
      # These require the LFS client to be built after checkout rather than before.
      # False for HTTP and SSH, where the LFS server address is known from the remote URL.
      def needs_post_checkout_lfs? : Bool
        false
      end
    end
  end
end
