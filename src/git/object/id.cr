module Git
  module Object
    # A 20-byte SHA-1 object identifier. Immutable value type; equality is byte-by-byte.
    struct Id
      def initialize(@bytes : Bytes)
      end

      ZERO = new(Bytes.new(20, 0u8))

      # Parses a 40-character hex string. Raises `Error` if the length is not exactly 40
      # or if the string contains non-hex characters.
      def self.from_hex(hex : String) : Id
        unless hex.size == 40
          raise Error.new("Invalid Object::Id: expected 40 hex chars, got #{hex.size}")
        end
        bytes = hex.hexbytes? || raise Error.new("Invalid Object::Id: non-hex characters in #{hex.inspect}")
        new(bytes)
      end

      # Constructs from a 20-byte slice (data is copied). Raises `Error` if not exactly 20 bytes.
      def self.from_bytes(bytes : Bytes) : Id
        unless bytes.size == 20
          raise Error.new("Invalid Object::Id: expected 20 bytes, got #{bytes.size}")
        end
        new(bytes.dup)
      end

      # Returns the lowercase 40-character hex string representation.
      def to_hex : String
        @bytes.hexstring
      end

      # Returns the raw 20-byte representation (shared slice — do not mutate).
      def to_bytes : Bytes
        @bytes
      end

      # Returns true if all bytes are zero (the null object id).
      def zero? : Bool
        @bytes.all?(&.zero?)
      end

      def ==(other : Id) : Bool
        @bytes == other.@bytes
      end

      def to_s(io : IO) : Nil
        io << to_hex
      end

      def hash(hasher)
        @bytes.hash(hasher)
      end
    end
  end
end
