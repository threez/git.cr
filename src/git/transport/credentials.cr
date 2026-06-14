require "base64"

module Git
  module Transport
    # Holds HTTP authentication credentials for a remote.
    #
    # Build instances via the factory methods or the top-level helpers:
    #   Git.bearer("ghp_abc123")
    #   Git.basic("user", "password")
    struct Credentials
      enum Kind
        Basic
        Bearer
      end

      # Whether this is a `Basic` or `Bearer` credential.
      getter kind : Kind

      # The encoded credential value: Base64(`user:password`) for Basic, raw token for Bearer.
      getter value : String

      private def initialize(@kind, @value)
      end

      # Creates Basic auth credentials. The `user:password` string is Base64-encoded
      # at construction time so `to_authorization_header` is allocation-free at call time.
      def self.basic(user : String, password : String) : Credentials
        new(Kind::Basic, Base64.strict_encode("#{user}:#{password}"))
      end

      # Creates Bearer token credentials (GitHub PATs, GitLab tokens, etc.).
      def self.bearer(token : String) : Credentials
        new(Kind::Bearer, token)
      end

      # Returns the full value for the `Authorization` HTTP header.
      def to_authorization_header : String
        case @kind
        in Kind::Basic  then "Basic #{@value}"
        in Kind::Bearer then "Bearer #{@value}"
        end
      end
    end
  end
end
