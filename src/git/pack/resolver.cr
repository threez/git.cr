require "compress/zlib"

module Git
  module Pack
    # A fully resolved pack object with its SHA-1, type, decompressed data, CRC32, and pack offset.
    struct ResolvedObject
      # SHA-1 of this object, computed from its type header and decompressed data.
      getter sha1 : Object::Id

      # Git object type (Commit, Tree, Blob, or Tag).
      getter type : ObjectType

      # Fully decompressed object data (no git header).
      getter data : Bytes

      # CRC32 of the compressed pack entry, used when writing the index.
      getter crc32 : UInt32

      # Byte offset of this object's entry in the packfile.
      getter pack_offset : Int64

      def initialize(@sha1, @type, @data, @crc32, @pack_offset)
      end
    end

    # Resolves all delta chains in a single packfile and computes SHA-1s for every object.
    #
    # When a *store* is passed to `resolve!`, any REF_DELTA base objects fetched from the
    # store (thin-pack support) are appended to the pack file on disk so that the resulting
    # pack+idx pair is self-contained and survives future opens without a store.
    #
    # Typical usage:
    # ```
    # resolver = Pack::Resolver.new(pack_path, count)
    # resolver.resolve!(store) # pass Object::Store for thin-pack support
    # Pack::IndexWriter.write_for_pack(resolver.sha1_map.values, pack_path)
    # ```
    class Resolver < Object::BlobSource
      # Map of SHA-1 → resolved object, populated by `resolve!`.
      getter sha1_map : Hash(Object::Id, ResolvedObject)

      def initialize(@pack_path : String, @object_count : Int32, @fs : FileSystem = FileSystem::Local.new)
        @sha1_map = Hash(Object::Id, ResolvedObject).new
        @offset_map = Hash(Int64, {ObjectType, Bytes}).new
        @external_bases = [] of {Object::Id, ObjectType, Bytes}
      end

      # Scans the packfile, resolves all delta chains, and populates sha1_map.
      # Pass an Object::BlobSource to resolve REF_DELTA bases from existing local packs
      # (required for thin packs produced by servers that know what objects the client has).
      # External bases are appended to the pack file so it is self-contained on reopen.
      def resolve!(store : Object::BlobSource? = nil) : Nil
        raw_objects = Scanner.scan(@pack_path, @object_count)

        pending = Array(RawObject).new

        raw_objects.each do |obj|
          if obj.type.delta?
            pending << obj
          else
            register!(obj.type, obj.data, obj.crc32, obj.offset)
          end
        end

        loop do
          progress = false

          pending.reject! do |obj|
            base = resolve_base(obj, store)
            next false unless base
            base_type, base_data = base

            resolved_data = Delta.apply(base_data, obj.data)
            register!(base_type, resolved_data, obj.crc32, obj.offset)
            progress = true
          end

          break if pending.empty?
          raise Pack::FileError.new("Cannot resolve #{pending.size} delta object(s) — broken delta chain") unless progress
        end

        # If external bases were fetched from the store (thin pack), append them to the
        # pack file on disk so it is self-contained for future opens without a store.
        complete_thin_pack! unless @external_bases.empty?
      end

      # Returns `{type, data}` for *sha1* if it was resolved from this pack, otherwise nil.
      def [](oid : Object::Id) : {ObjectType, Bytes}?
        obj = @sha1_map[oid]?
        obj ? {obj.type, obj.data} : nil
      end

      # Yields every resolved object as `(sha1, type, data)`.
      def each(&block : Object::Id, ObjectType, Bytes ->) : Nil
        @sha1_map.each { |sha1, obj| block.call(sha1, obj.type, obj.data) }
      end

      private def resolve_base(obj : RawObject, store : Object::BlobSource? = nil) : {ObjectType, Bytes}?
        if obj.type.ofs_delta?
          @offset_map[obj.delta_base_offset.not_nil!]? # ameba:disable Lint/NotNil
        else
          sha1 = obj.delta_base_sha1.not_nil! # ameba:disable Lint/NotNil
          found = @sha1_map[sha1]?.try { |resolved| {resolved.type, resolved.data} }
          if found
            found
          elsif store && (external = store[sha1])
            ext_type, ext_data = external
            # Only record each external base once.
            unless @external_bases.any? { |id, _, _| id == sha1 }
              @external_bases << {sha1, ext_type, ext_data}
            end
            external
          end
        end
      end

      private def register!(type : ObjectType, data : Bytes, crc32 : UInt32, offset : Int64) : Nil
        sha1 = Delta.git_sha1(type, data)
        resolved = ResolvedObject.new(sha1, type, data, crc32, offset)
        @sha1_map[sha1] = resolved
        @offset_map[offset] = {type, data}
      end

      # Appends external base objects to the pack file and updates sha1_map with their offsets.
      # Rewrites the trailing 20-byte SHA-1 to cover all bytes including the new objects.
      private def complete_thin_pack! : Nil
        pack_size = @fs.size(@pack_path)
        # The trailing SHA-1 of the original pack occupies the last 20 bytes.
        body_end = pack_size - 20

        # Compute SHA-1 over the pack body (everything except the old trailing SHA-1).
        digest = Digest::SHA1.new
        @fs.open(@pack_path, "rb") do |file|
          remaining = body_end
          buf = Bytes.new(65536)
          while remaining > 0
            to_read = Math.min(remaining, buf.size.to_i64).to_i32
            n = file.read(buf[0, to_read])
            break if n == 0
            digest.update(buf[0, n])
            remaining -= n
          end
        end

        # Append the external base objects, then rewrite the trailing SHA-1.
        @fs.open(@pack_path, "r+b") do |file|
          # Seek to overwrite the old trailing SHA-1.
          file.seek(-20, IO::Seek::End)

          @external_bases.each do |sha1, type, data|
            obj_offset = file.pos.to_i64
            entry = encode_pack_object(type, data)
            file.write(entry)
            digest.update(entry)

            crc32 = CRC32.digest(entry)
            resolved = ResolvedObject.new(sha1, type, data, crc32, obj_offset)
            @sha1_map[sha1] = resolved
            @offset_map[obj_offset] = {type, data}
          end

          file.write(digest.final)
        end
      end

      # Encodes a single non-delta pack object (type+size varint header + zlib body).
      private def encode_pack_object(type : ObjectType, data : Bytes) : Bytes
        buf = IO::Memory.new

        # Write type+size varint header (git pack object header format).
        size = data.size.to_i64
        first_byte = ((type.value.to_u8 & 0x07_u8) << 4) | (size & 0x0f).to_u8
        size >>= 4
        if size > 0
          first_byte |= 0x80_u8
        end
        buf.write_byte(first_byte)
        while size > 0
          byte = (size & 0x7f).to_u8
          size >>= 7
          byte |= 0x80_u8 if size > 0
          buf.write_byte(byte)
        end

        # Write zlib-compressed data.
        Compress::Zlib::Writer.open(buf, &.write(data))

        buf.to_slice
      end
    end
  end
end
