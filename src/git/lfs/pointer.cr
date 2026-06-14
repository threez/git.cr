module Git
  module LFS
    POINTER_HEADER = "version https://git-lfs.github.com/spec/v1"

    # Represents a Git LFS pointer file stored as a regular blob in a pack.
    struct Pointer
      # SHA-256 hex digest of the actual file content (64 lowercase hex chars).
      getter oid : String

      # Byte size of the actual file content.
      getter size : Int64

      def initialize(@oid : String, @size : Int64)
      end

      # Returns a `Pointer` if *data* is a valid LFS pointer blob, `nil` otherwise.
      # LFS pointers are always < 200 bytes, so large blobs are rejected cheaply.
      def self.parse?(data : Bytes) : Pointer?
        return nil if data.size > 200
        text = String.new(data)
        return nil unless text.starts_with?(POINTER_HEADER)
        oid = text.match(/^oid sha256:([0-9a-f]{64})$/m).try(&.[1])
        size = text.match(/^size (\d+)$/m).try(&.[1].to_i64?)
        return nil unless oid && size
        new(oid, size)
      end
    end
  end
end
