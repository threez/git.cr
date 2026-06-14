module Git
  # The capability set advertised by a `git-upload-pack` server.
  # Parsed from the NUL-separated suffix of the first ref advertisement line.
  struct Protocol::CapabilitySet
    AGENT         = "crystal-git/0.1.0"
    SIDE_BAND_64K = "side-band-64k"
    OFS_DELTA     = "ofs-delta"

    def initialize(@caps : Hash(String, String?))
    end

    def self.parse(raw : String) : CapabilitySet
      caps = {} of String => String?
      raw.split(' ').each do |cap|
        next if cap.empty?
        if eq_idx = cap.index('=')
          caps[cap[0, eq_idx]] = cap[eq_idx + 1..]
        else
          caps[cap] = nil
        end
      end
      new(caps)
    end

    def includes?(cap : String) : Bool
      @caps.has_key?(cap)
    end

    def [](key : String) : String?
      @caps[key]?
    end

    def agent : String?
      @caps["agent"]?
    end

    # Returns true if the server advertised `side-band-64k` (packfile and progress on separate channels).
    def side_band_64k? : Bool
      includes?(SIDE_BAND_64K)
    end

    # Returns true if the server advertised `ofs-delta` (offset-based delta base references).
    def ofs_delta? : Bool
      includes?(OFS_DELTA)
    end

    # Returns the target of a `symref` capability, or nil.
    # For example, `symref("HEAD")` returns `"refs/heads/main"` when the server advertises
    # `symref=HEAD:refs/heads/main`.
    def symref(name : String) : String?
      @caps.each do |k, v|
        return v if k == "symref" && v && v.starts_with?("#{name}:")
      end
      nil
    end

    # Returns the capability suffix to append to the first want line.
    # Only requests capabilities the server advertised.
    def to_want_line_suffix : String
      parts = [] of String
      parts << SIDE_BAND_64K if side_band_64k?
      parts << OFS_DELTA if ofs_delta?
      parts << "agent=#{AGENT}"
      " " + parts.join(" ")
    end
  end
end
