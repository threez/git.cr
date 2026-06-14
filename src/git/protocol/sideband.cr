module Git
  module Protocol
    # Read-only IO that unwraps Git sideband-64k multiplexing from a pkt-line stream.
    # Only `#read` is implemented; `#write` always raises `IO::Error`.
    #
    # Channel 1 (0x01): packfile data — forwarded to reads.
    # Channel 2 (0x02): progress lines — parsed and delivered to on_progress one line at a time.
    # Channel 3 (0x03): error messages — raises ProtocolError.
    class SidebandReader < IO
      def initialize(@reader : PktLine::Reader, on_progress : ProgressCallback? = nil)
        @buffer = Bytes.empty
        @line_buffer = on_progress ? ProgressLineBuffer.new(on_progress) : nil
        @eof = false
      end

      def read(slice : Bytes) : Int32
        return 0 if @eof

        while @buffer.empty?
          type, data = @reader.read_packet
          case type
          when PktLine::Type::Flush
            @eof = true
            return 0
          when PktLine::Type::Data
            pkt = data.not_nil! # ameba:disable Lint/NotNil
            raise ProtocolError.new("Empty sideband packet") if pkt.empty?
            case pkt[0]
            when 1u8
              @buffer = pkt[1..]
            when 2u8
              @line_buffer.try &.write(pkt[1..])
            when 3u8
              raise ProtocolError.new("Remote error: #{String.new(pkt[1..]).strip}")
            else
              raise ProtocolError.new("Unknown sideband channel: #{pkt[0]}")
            end
          end
        end

        n = Math.min(slice.size, @buffer.size)
        @buffer[0, n].copy_to(slice)
        @buffer = @buffer[n..]
        n
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("#{self.class} is read-only — sideband data flows from remote to client only")
      end
    end
  end
end
