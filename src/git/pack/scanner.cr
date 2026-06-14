module Git
  module Pack
    PACK_EXT = ".pack"
    IDX_EXT  = ".idx"

    # One unresolved object parsed from a packfile scan.
    # Delta objects (`OfsDelta`, `RefDelta`) still reference their base
    # by pack offset or SHA-1; `Resolver` turns them into standalone objects.
    struct RawObject
      # Byte offset of this entry in the packfile.
      getter offset : Int64

      # Raw pack object type, including delta types (`OfsDelta`, `RefDelta`).
      getter type : ObjectType

      # Uncompressed size of the object data as declared in the pack entry header.
      getter size : Int64

      # For `OfsDelta` objects: negative offset from this entry to the base object.
      getter delta_base_offset : Int64?

      # For `RefDelta` objects: SHA-1 of the base object.
      getter delta_base_sha1 : Object::Id?

      # Decompressed object data (raw delta instructions for delta types).
      getter data : Bytes

      # CRC32 of the compressed pack entry bytes (header + compressed payload).
      getter crc32 : UInt32

      def initialize(@offset, @type, @size, @delta_base_offset, @delta_base_sha1, @data, @crc32)
      end
    end

    module Scanner
      PACK_HEADER_SIZE = 12

      # Loads the entire packfile into memory and parses each object header.
      # Returns an Array(RawObject) with decompressed object data.
      # Loading into memory is required because LibZ.inflate needs a Bytes pointer
      # and OFS_DELTA resolution needs random access to earlier offsets.
      def self.scan(pack_path : String, object_count : Int32, fs : FileSystem = FileSystem::Local.new) : Array(RawObject)
        pack = fs.read(pack_path).to_slice
        objects = Array(RawObject).new(object_count)

        pos = PACK_HEADER_SIZE

        object_count.times do
          obj_start = pos

          # Parse type+size varint
          byte = pack[pos].to_u32
          pos += 1
          type_int = (byte >> 4) & 0x07
          size = (byte & 0x0f).to_i64
          shift = 4

          while byte & 0x80 != 0
            byte = pack[pos].to_u32
            pos += 1
            size |= ((byte & 0x7f).to_i64 << shift)
            shift += 7
          end

          obj_type = ObjectType.from_value(type_int.to_u8)

          base_offset = nil.as(Int64?)
          base_sha1 = nil.as(Object::Id?)

          if obj_type.ofs_delta?
            byte = pack[pos].to_u64
            pos += 1
            neg_offset = (byte & 0x7f).to_i64

            while byte & 0x80 != 0
              neg_offset += 1
              neg_offset <<= 7
              byte = pack[pos].to_u64
              pos += 1
              neg_offset += (byte & 0x7f)
            end

            base_offset = obj_start.to_i64 - neg_offset
          elsif obj_type.ref_delta?
            base_sha1 = Object::Id.from_bytes(pack[pos, 20])
            pos += 20
          end

          if size < 0 || size > Int32::MAX
            raise Pack::FileError.new("Pack object declares invalid uncompressed size: #{size}")
          end
          data, compressed_len = Inflate.at(pack, pos, size.to_i32)
          crc32 = CRC32.digest(pack[obj_start, pos - obj_start + compressed_len])
          pos += compressed_len

          objects << RawObject.new(
            obj_start.to_i64, obj_type, size,
            base_offset, base_sha1, data, crc32
          )
        end

        objects
      end
    end
  end
end
