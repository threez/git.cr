module Git
  module Protocol
    # Protocol v2 session: uses the ls-refs + fetch command model.
    # Transport-agnostic — all exchanges go through `Transport#request`.
    class V2 < Session
      LS_REFS_COMMAND  = "command=ls-refs"
      FETCH_COMMAND    = "command=fetch"
      SYMREFS          = "symrefs"
      PEEL             = "peel"
      SHALLOW_INFO     = "shallow-info"
      PACKFILE_SECTION = "packfile"

      def initialize(@transport : Transport::Base)
      end

      def refs : Array(Repository::Ref)
        result = [] of Repository::Ref
        @transport.request(V2.build_ls_refs_body) { |io| result = V2.parse_ls_refs_response(io) }
        result
      end

      def fetch(
        wants : Array(Object::Id),
        haves : Array(Object::Id) = [] of Object::Id,
        depth : Int32? = nil,
        shallows : Array(Object::Id) = [] of Object::Id,
        on_progress : ProgressCallback? = nil,
        &blk : IO, Array(Object::Id), Array(Object::Id) ->
      ) : Nil
        body = V2.build_fetch_body(wants, haves, depth, shallows)
        @transport.request(body) do |io|
          pack_io, new_shallows, unshallowed = V2.parse_fetch_response(io, on_progress)
          blk.call(pack_io, new_shallows, unshallowed)
        end
      end

      def close : Nil
        @transport.close
      end

      # ── Wire-format static methods ──────────────────────────────────────────

      def self.build_ls_refs_body : Bytes
        io = IO::Memory.new
        w = PktLine::Writer.new(io)
        w.write_data("#{LS_REFS_COMMAND}\n")
        w.write_delim
        w.write_data("#{SYMREFS}\n")
        w.write_data("#{PEEL}\n")
        w.write_flush
        io.to_slice
      end

      def self.parse_ls_refs_response(io : IO) : Array(Repository::Ref)
        refs = [] of Repository::Ref
        reader = PktLine::Reader.new(io)
        reader.each_data_packet do |data|
          line = String.new(data).chomp
          parts = line.split(' ', 2)
          next if parts.size < 2
          oid = Git.oid(parts[0])
          attrs = parts[1].split(' ')
          name = attrs[0]
          symref_target = attrs[1..]
            .find(&.starts_with?("symref-target:"))
            .try { |attr| attr["symref-target:".size..] }
          refs << Repository::Ref.new(name, oid, symref_target)
        end
        refs
      end

      def self.build_fetch_body(
        wants : Array(Object::Id),
        haves : Array(Object::Id) = [] of Object::Id,
        depth : Int32? = nil,
        shallows : Array(Object::Id) = [] of Object::Id,
      ) : Bytes
        io = IO::Memory.new
        w = PktLine::Writer.new(io)
        w.write_data("#{FETCH_COMMAND}\n")
        w.write_delim
        wants.each { |oid| w.write_data("#{WANT}#{oid.to_hex}\n") }
        shallows.each { |oid| w.write_data("#{SHALLOW}#{oid.to_hex}\n") }
        w.write_data("#{DEEPEN}#{depth}\n") if depth
        haves.each { |oid| w.write_data("#{HAVE}#{oid.to_hex}\n") }
        w.write_data("#{DONE}\n")
        w.write_flush
        io.to_slice
      end

      # Parses a v2 fetch response. Handles an optional `shallow-info` section before
      # the mandatory `packfile` section. Returns the pack IO (sideband-wrapped) plus
      # shallow boundary changes.
      def self.parse_fetch_response(
        io : IO,
        on_progress : ProgressCallback? = nil,
      ) : {IO, Array(Object::Id), Array(Object::Id)}
        reader = PktLine::Reader.new(io)
        new_shallows = [] of Object::Id
        unshallowed = [] of Object::Id

        loop do
          pkt_type, pkt_data = reader.read_packet
          case pkt_type
          when PktLine::Type::Flush
            raise ProtocolError.new("v2 fetch response ended without packfile section")
          when PktLine::Type::Data
            section = String.new(pkt_data.not_nil!).chomp # ameba:disable Lint/NotNil
            case section
            when SHALLOW_INFO
              loop do
                t2, d2 = reader.read_packet
                break unless t2 == PktLine::Type::Data
                Session.parse_shallow_line(String.new(d2.not_nil!).chomp, new_shallows, unshallowed) # ameba:disable Lint/NotNil
              end
            when PACKFILE_SECTION
              pack_io = SidebandReader.new(reader, on_progress)
              return {pack_io, new_shallows, unshallowed}
            end
          end
        end
      end
    end
  end
end
