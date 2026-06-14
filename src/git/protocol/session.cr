module Git
  module Protocol
    SERVICE   = "git-upload-pack"
    VERSION_2 = "version=2"
    WANT      = "want "
    HAVE      = "have "
    SHALLOW   = "shallow "
    DEEPEN    = "deepen "
    DONE      = "done"
    UNSHALLOW = "unshallow "

    # Transport-agnostic interface for a single upload-pack session.
    # Obtained from `Negotiator.open`; hides whether the session speaks v1 or v2.
    abstract class Session
      # Returns the refs advertised by the remote for this session.
      # Implementations may serve the result from a cache populated during the initial
      # handshake (V1::HTTP, V1::Pipe) or issue a dedicated network request (V2).
      # Call at most once per session; do not rely on repeated calls returning updated data.
      abstract def refs : Array(Repository::Ref)

      # Fetches a pack from the server. Yields the pack IO, new shallow OIDs, and
      # any OIDs removed from the shallow boundary, then returns.
      # The pack IO is valid only for the duration of the block; callers must fully
      # consume it (e.g. via `Pack::File.receive`) before the block exits.
      abstract def fetch(
        wants : Array(Object::Id),
        haves : Array(Object::Id) = [] of Object::Id,
        depth : Int32? = nil,
        shallows : Array(Object::Id) = [] of Object::Id,
        on_progress : ProgressCallback? = nil,
        & : IO, Array(Object::Id), Array(Object::Id) ->
      ) : Nil

      # Closes the session and the underlying transport.
      # May raise `TransportError` if teardown fails (e.g. non-zero subprocess exit).
      abstract def close : Nil

      # Parses a single shallow/unshallow line, appending to the appropriate array.
      # Returns true if the line was recognised as a shallow or unshallow entry.
      protected def self.parse_shallow_line(
        line : String,
        new_shallows : Array(Object::Id),
        unshallowed : Array(Object::Id),
      ) : Bool
        if line.starts_with?(SHALLOW)
          new_shallows << Git.oid(line[SHALLOW.size..].strip)
          true
        elsif line.starts_with?(UNSHALLOW)
          unshallowed << Git.oid(line[UNSHALLOW.size..].strip)
          true
        else
          false
        end
      end
    end
  end
end
