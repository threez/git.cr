module Git
  # A Git reference: a named pointer to an `Object::Id`.
  # Names follow the full refname convention, e.g. `refs/heads/main`, `refs/tags/v1.0`, `HEAD`.
  struct Repository::Ref
    HEAD_NAME      = "HEAD"
    HEADS_PREFIX   = "refs/heads/"
    TAGS_PREFIX    = "refs/tags/"
    REMOTES_PREFIX = "refs/remotes/"

    # Full refname, e.g. `"refs/heads/main"`, `"refs/tags/v1.0"`, or `"HEAD"`.
    getter name : String

    # The commit (or tag object) this ref points to.
    getter oid : Object::Id

    # For the `HEAD` ref: the full refname it points to (e.g. `"refs/heads/main"`).
    # Populated from the v2 `symref-target` attribute or the v1 `symref` capability.
    # Nil for non-symbolic refs or when the server did not advertise a symref.
    getter symref_target : String?

    def initialize(@name, @oid, @symref_target = nil)
    end

    # Parses a ref advertisement line. Returns the Ref and, for the first
    # line (which contains a NUL-separated capability string), the raw
    # capability string. Returns nil for the capability string on subsequent lines.
    def self.parse_advertisement_line(line : String) : {Repository::Ref, String?}
      line = line.chomp
      ref_part, caps_raw = if nul_idx = line.index('\0')
                             {line[0, nul_idx], line[nul_idx + 1..].as(String?)}
                           else
                             {line, nil.as(String?)}
                           end
      oid_str, name = split_ref_part(ref_part)
      {new(name, Git.oid(oid_str)), caps_raw}
    end

    # Returns true if this is the synthetic `HEAD` ref.
    def head? : Bool
      @name == HEAD_NAME
    end

    # Returns true if this is a branch ref (under `refs/heads/`).
    def branch? : Bool
      @name.starts_with?(HEADS_PREFIX)
    end

    # Returns true if this is a tag ref (under `refs/tags/`).
    def tag? : Bool
      @name.starts_with?(TAGS_PREFIX)
    end

    # Returns the branch name without the `refs/heads/` prefix, or nil for non-branch refs.
    def branch_name : String?
      @name.lchop?(HEADS_PREFIX)
    end

    # Returns the tag name without the `refs/tags/` prefix, or nil for non-tag refs.
    def tag_name : String?
      @name.lchop?(TAGS_PREFIX)
    end

    def to_s(io : IO) : Nil
      io << @oid.to_hex << " " << @name
    end

    private def self.split_ref_part(part : String) : {String, String}
      space_idx = part.index(' ')
      raise ProtocolError.new("Invalid ref advertisement line: #{part.inspect}") unless space_idx
      {part[0, space_idx], part[space_idx + 1..]}
    end
  end
end
