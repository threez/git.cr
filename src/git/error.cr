module Git
  # Base error class for all Git library errors.
  class Error < Exception; end

  # Raised when the remote violates the Git wire protocol.
  class ProtocolError < Error; end

  # Raised when an SSH or file subprocess exits with a non-zero status.
  class TransportError < Error; end

  # Raised when a packfile is malformed or its header is invalid.
  class Pack::FileError < Error; end

  # Raised for repository-level failures: missing `.git/`, detached HEAD, unknown ref, etc.
  class RepositoryError < Error; end

  # Raised by `pull` when the remote history has diverged from local (e.g. force-push).
  # Rescue this specifically to implement pull-or-reset logic, or use `sync` instead.
  class NonFastForwardError < Error; end

  # Raised when an HTTP remote returns 401 Unauthorized.
  # Rescue this to prompt for credentials and retry with `Credentials.basic` or `Credentials.bearer`.
  class AuthenticationError < TransportError; end

  # Raised when a `.lock` file already exists, indicating a concurrent writer holds the lock.
  # Rescue this to implement retry logic or surface as a user-facing error.
  class LockError < Error; end
end
