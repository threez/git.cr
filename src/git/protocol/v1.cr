module Git
  module Protocol
    # Protocol v1 wire-format helpers and two concrete Session implementations.
    #
    # - `V1::HTTP`  — stateless (HTTP/HTTPS): shallow lines arrive inside sideband.
    # - `V1::Pipe`  — stateful (SSH / file://): shallow lines precede sideband; NAK present.
    #
    # Refs are supplied at construction time (parsed during negotiation).
    module V1
      # ── Concrete sessions ────────────────────────────────────────────────────

      # HTTP v1 session: one POST per exchange; shallow lines wrapped in sideband.
      class HTTP < Session
        def initialize(
          @transport : Transport::Base,
          @refs : Array(Repository::Ref),
          @caps : CapabilitySet,
        )
        end

        def refs : Array(Repository::Ref)
          @refs
        end

        def fetch(
          wants : Array(Object::Id),
          haves : Array(Object::Id) = [] of Object::Id,
          depth : Int32? = nil,
          shallows : Array(Object::Id) = [] of Object::Id,
          on_progress : ProgressCallback? = nil,
          &blk : IO, Array(Object::Id), Array(Object::Id) ->
        ) : Nil
          body = V1.build_want_body(wants, @caps, haves, depth, shallows)
          @transport.request(body) do |io|
            pack_io, new_shallows, unshallowed = V1.parse_stateless_fetch_response(io, @caps, depth, shallows, on_progress)
            blk.call(pack_io, new_shallows, unshallowed)
          end
        end

        def close : Nil
          @transport.close
        end
      end

      # SSH / file:// v1 session: stateful; shallow lines before sideband; NAK present.
      class Pipe < Session
        def initialize(
          @transport : Transport::Base,
          @refs : Array(Repository::Ref),
          @caps : CapabilitySet,
        )
        end

        def refs : Array(Repository::Ref)
          @refs
        end

        def fetch(
          wants : Array(Object::Id),
          haves : Array(Object::Id) = [] of Object::Id,
          depth : Int32? = nil,
          shallows : Array(Object::Id) = [] of Object::Id,
          on_progress : ProgressCallback? = nil,
          &blk : IO, Array(Object::Id), Array(Object::Id) ->
        ) : Nil
          body = V1.build_want_body(wants, @caps, haves, depth, shallows)
          @transport.request(body) do |io|
            pack_io, new_shallows, unshallowed = V1.parse_stateful_fetch_response(io, @caps, depth, shallows, on_progress)
            blk.call(pack_io, new_shallows, unshallowed)
          end
        end

        def close : Nil
          @transport.close
        end
      end

      # ── Wire-format static methods ──────────────────────────────────────────

      def self.build_want_body(
        wants : Array(Object::Id),
        caps : CapabilitySet,
        haves : Array(Object::Id) = [] of Object::Id,
        depth : Int32? = nil,
        shallows : Array(Object::Id) = [] of Object::Id,
      ) : Bytes
        body_io = IO::Memory.new
        writer = PktLine::Writer.new(body_io)

        wants.each_with_index do |oid, i|
          suffix = i == 0 ? caps.to_want_line_suffix : ""
          writer.write_data("#{WANT}#{oid.to_hex}#{suffix}\n")
        end
        shallows.each { |oid| writer.write_data("#{SHALLOW}#{oid.to_hex}\n") }
        writer.write_data("#{DEEPEN}#{depth}\n") if depth
        writer.write_flush

        haves.each { |oid| writer.write_data("#{HAVE}#{oid.to_hex}\n") }
        writer.write_data("#{DONE}\n")

        body_io.to_slice
      end

      # Parses a v1 response from a stateless (HTTP) transport.
      # The upload-pack response on a stateless transport begins with a raw NAK/ACK pkt-line
      # (not wrapped in sideband), followed by the sideband-framed pack stream.
      # We must consume the NAK before handing the reader to SidebandReader, mirroring
      # what parse_stateful_fetch_response already does at the reader.read_packet call below.
      def self.parse_stateless_fetch_response(
        io : IO,
        caps : CapabilitySet,
        depth : Int32?,
        shallows : Array(Object::Id),
        on_progress : ProgressCallback?,
      ) : {IO, Array(Object::Id), Array(Object::Id)}
        reader = PktLine::Reader.new(io)
        new_shallows = [] of Object::Id
        unshallowed = [] of Object::Id
        if depth || !shallows.empty?
          # Shallow lines arrive as raw pkt-lines before sideband on stateless transport too.
          new_shallows, unshallowed, nak_consumed = consume_shallow_stateful(reader)
          reader.read_packet unless nak_consumed
        else
          reader.read_packet # consume the NAK
        end
        pack_io = caps.side_band_64k? ? SidebandReader.new(reader, on_progress) : io
        {pack_io, new_shallows, unshallowed}
      end

      # Parses a v1 response from a stateful (SSH/file) transport.
      # Shallow pkt-lines appear before the pack data as raw pkt-lines (not in sideband).
      # The server may also omit the flush and send NAK directly after shallow lines.
      def self.parse_stateful_fetch_response(
        io : IO,
        caps : CapabilitySet,
        depth : Int32?,
        shallows : Array(Object::Id),
        on_progress : ProgressCallback?,
      ) : {IO, Array(Object::Id), Array(Object::Id)}
        reader = PktLine::Reader.new(io)
        new_shallows = [] of Object::Id
        unshallowed = [] of Object::Id
        nak_consumed = false
        if depth || !shallows.empty?
          new_shallows, unshallowed, nak_consumed = consume_shallow_stateful(reader)
        end
        reader.read_packet unless nak_consumed
        pack_io = caps.side_band_64k? ? SidebandReader.new(reader, on_progress) : io
        {pack_io, new_shallows, unshallowed}
      end

      # Parses ref advertisement packets into a (refs, caps) pair.
      def self.parse_ref_advertisement(reader : PktLine::Reader) : {Array(Repository::Ref), CapabilitySet}
        packets = [] of Bytes
        reader.each_data_packet { |pkt| packets << pkt.dup }
        parse_ref_advertisement_from_packets(packets)
      end

      def self.parse_ref_advertisement_from_packets(packets : Array(Bytes)) : {Array(Repository::Ref), CapabilitySet}
        refs = [] of Repository::Ref
        caps = CapabilitySet.parse("")
        first = true
        packets.each do |data|
          ref, caps_raw = Repository::Ref.parse_advertisement_line(String.new(data))
          refs << ref
          if first && (raw = caps_raw)
            caps = CapabilitySet.parse(raw)
            first = false
          end
        end
        # Annotate HEAD with the symref capability so resolve_target can use it
        # instead of falling back to OID-matching (which picks the wrong branch when
        # two branches share a commit).
        if head_idx = refs.index(&.head?)
          if symref_target = caps.symref("HEAD").try { |v| v.split(':', 2)[1]? }
            refs[head_idx] = Repository::Ref.new(refs[head_idx].name, refs[head_idx].oid, symref_target)
          end
        end
        {refs, caps}
      end

      # ── Private helpers ─────────────────────────────────────────────────────

      # Reads shallow/unshallow pkt-lines until the flush packet (stateless transport).
      private def self.consume_shallow_response(
        reader : PktLine::Reader,
      ) : {Array(Object::Id), Array(Object::Id)}
        new_shallows = [] of Object::Id
        unshallowed = [] of Object::Id
        reader.each_data_packet do |data|
          Session.parse_shallow_line(String.new(data), new_shallows, unshallowed)
        end
        {new_shallows, unshallowed}
      end

      # Like `consume_shallow_response` but for stateful transports.
      # Servers sometimes omit the flush and send NAK/ACK directly after shallow lines.
      # Returns {new_shallows, unshallowed, nak_consumed}.
      private def self.consume_shallow_stateful(
        reader : PktLine::Reader,
      ) : {Array(Object::Id), Array(Object::Id), Bool}
        new_shallows = [] of Object::Id
        unshallowed = [] of Object::Id
        loop do
          type, data = reader.read_packet
          case type
          when PktLine::Type::Flush
            return {new_shallows, unshallowed, false}
          when PktLine::Type::Data
            line = String.new(data.not_nil!) # ameba:disable Lint/NotNil
            unless Session.parse_shallow_line(line, new_shallows, unshallowed)
              return {new_shallows, unshallowed, true}
            end
          else
            return {new_shallows, unshallowed, false}
          end
        end
      end
    end
  end
end
