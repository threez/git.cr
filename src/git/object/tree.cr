module Git
  module Object
    # One entry in a git tree object. Wire format: `"<octal-mode> <name>\0<20-byte-sha1>"`.
    struct TreeEntry
      # Octal git file mode (e.g. `0o100644` for a regular file, `0o040000` for a subtree).
      getter mode : UInt32

      # File or directory name for this entry (no path separator).
      getter name : String

      # SHA-1 of the blob or subtree object.
      getter oid : Id

      def initialize(@mode, @name, @oid)
      end

      # Returns true if this entry is a subtree (mode `040000`).
      def directory? : Bool
        # Mode 040000 (octal) = 16384 decimal
        @mode == 0o40000_u32
      end

      # Returns true if any execute permission bit is set (mode `100755`-style).
      def executable? : Bool
        (@mode & 0o111_u32) != 0
      end

      # Returns true if this entry is a symbolic link (mode `0120000`).
      def symlink? : Bool
        # Mode 0120000 (octal) = 40960 decimal
        @mode == 0o120000_u32
      end

      # Returns true if this entry is a gitlink / submodule (mode `0160000`).
      def gitlink? : Bool
        @mode == 0o160000_u32
      end
    end

    # Parser for the binary git tree object format.
    module Tree
      # Parses the binary tree object format:
      # Repeating: "<octal-mode> <name>\0<20-byte-sha1>"
      def self.parse(data : Bytes) : Array(TreeEntry)
        entries = [] of TreeEntry
        pos = 0

        while pos < data.size
          # Find space separating mode from name
          space_pos = find_byte(data, pos, 0x20_u8)
          raise ProtocolError.new("Tree entry missing mode/name separator at pos #{pos}") unless space_pos

          mode_str = String.new(data[pos, space_pos - pos])
          mode = mode_str.to_u32(8) rescue raise ProtocolError.new("Invalid tree entry mode: #{mode_str.inspect}")

          name_start = space_pos + 1

          # Find NUL terminating the name
          nul_pos = find_byte(data, name_start, 0x00_u8)
          raise ProtocolError.new("Tree entry missing NUL terminator at pos #{name_start}") unless nul_pos

          name = String.new(data[name_start, nul_pos - name_start])
          validate_tree_entry_name!(name)

          sha_start = nul_pos + 1
          raise ProtocolError.new("Tree entry SHA1 out of bounds") if sha_start + 20 > data.size

          oid = Id.from_bytes(data[sha_start, 20])

          entries << TreeEntry.new(mode, name, oid)
          pos = sha_start + 20
        end

        entries
      end

      # Git tree entry names are single path components (no slashes) and must never
      # contain path traversal sequences. A malicious remote that violates this could
      # write files outside the worktree on checkout.
      private def self.validate_tree_entry_name!(name : String) : Nil
        if name.empty? || name == "." || name == ".."
          raise ProtocolError.new("Invalid tree entry name: #{name.inspect}")
        end
        if name.includes?('/') || name.includes?('\0') || name.includes?('\\')
          raise ProtocolError.new("Invalid tree entry name (path separator): #{name.inspect}")
        end
        # Case-insensitive .git check blocks hooks/config injection on any platform.
        if name.downcase == ".git"
          raise ProtocolError.new("Invalid tree entry name '.git': #{name.inspect}")
        end
      end

      private def self.find_byte(data : Bytes, start : Int32, byte : UInt8) : Int32?
        (start...data.size).each do |i|
          return i if data[i] == byte
        end
        nil
      end
    end
  end
end
