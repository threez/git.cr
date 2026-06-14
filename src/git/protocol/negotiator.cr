module Git
  module Protocol
    # Detects protocol version from a transport's initial handshake and returns
    # the appropriate `Session` (`V1` or `V2`).
    #
    # HTTP: reads the GET info/refs response to detect the version.
    # Pipe: reads the first pkt-line from stdout (process must be open already).
    class Negotiator
      # Opens a session for *transport*: calls `transport.open`, then reads the
      # initial version advertisement via `transport.handshake_io` and returns
      # the appropriate `Session` (V1::HTTP, V1::Pipe, or V2).
      def self.open(transport : Transport::Base) : Session
        transport.open
        detect_version_from_io(transport.handshake_io, stateless: transport.stateless?, transport: transport)
      end

      # Parses the version advertisement from *io* and returns a V1 or V2 session.
      #
      # ### Parameters
      #
      # *io* — The handshake IO produced by `transport.handshake_io`.
      #
      # *stateless* — `true` for HTTP (no NAK/ACK; shallow lines wrapped in sideband);
      # `false` for pipe transports (stateful; shallow lines before sideband; NAK present).
      #
      # *transport* — Attached to the returned session for subsequent fetch requests.
      def self.detect_version_from_io(
        io : IO,
        stateless : Bool,
        transport : Transport::Base,
      ) : Session
        reader = PktLine::Reader.new(io)
        type, first_data = reader.read_packet

        if v2?(type, first_data)
          reader.each_data_packet { } # drain capability advertisement
          V2.new(transport)
        elsif stateless
          # HTTP v1: first packet was service announcement; skip flush, then read refs
          reader.read_packet # flush after service announcement
          refs, caps = V1.parse_ref_advertisement(reader)
          V1::HTTP.new(transport, refs, caps)
        else
          # Pipe v1: first packet IS the first ref line (no service announcement)
          packets = [] of Bytes
          packets << first_data.dup if type == PktLine::Type::Data && first_data
          reader.each_data_packet { |pkt| packets << pkt.dup }
          refs, caps = packets.empty? ? {[] of Repository::Ref, CapabilitySet.parse("")} : V1.parse_ref_advertisement_from_packets(packets)
          V1::Pipe.new(transport, refs, caps)
        end
      end

      private def self.v2?(type : PktLine::Type, data : Bytes?) : Bool
        type == PktLine::Type::Data && data != nil && String.new(data.not_nil!) == "version 2\n" # ameba:disable Lint/NotNil
      end
    end
  end
end
