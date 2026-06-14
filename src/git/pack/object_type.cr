module Git
  module Pack
    # Pack object type codes as defined by the Git packfile v2 format.
    # `Commit`, `Tree`, `Blob`, and `Tag` are standalone objects;
    # `OfsDelta` and `RefDelta` are delta-compressed and require base resolution.
    enum ObjectType : UInt8
      Commit   = 1
      Tree     = 2
      Blob     = 3
      Tag      = 4
      OfsDelta = 6
      RefDelta = 7

      # Returns true for `OfsDelta` or `RefDelta` — objects that need base resolution before use.
      def delta? : Bool
        ofs_delta? || ref_delta?
      end

      # Returns the lowercase git type string (`"commit"`, `"tree"`, `"blob"`, `"tag"`).
      # Raises `Error` for delta types, which have no standalone type string.
      def to_git_type_string : String
        case self
        when Commit then "commit"
        when Tree   then "tree"
        when Blob   then "blob"
        when Tag    then "tag"
        else             raise Error.new("No type string for delta type #{self}")
        end
      end
    end
  end
end
