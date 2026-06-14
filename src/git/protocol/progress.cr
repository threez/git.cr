module Git
  module Protocol
    # A single parsed progress message from the remote git server (sideband channel 2).
    #
    # Git emits three kinds of progress lines:
    # - Percentage: `"Counting objects:  42% (3/7)"` or `"Counting objects: 100% (7/7), done."`
    # - Count: `"Enumerating objects: 5, done."`
    # - Free-form: `"Total 5 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)"`
    struct ProgressMessage
      # The task name, e.g. `"Counting objects"`, `"Compressing objects"`.
      # For free-form lines this equals `raw`.
      getter task : String

      # Current progress count (numerator). Set for both percentage and count messages.
      getter current : Int32?

      # Total count (denominator). Set only for percentage messages.
      getter total : Int32?

      # Progress percentage (0–100). Nil for count-only and free-form messages.
      getter percent : Int32?

      # True when the line ends with `", done."` — the task is complete.
      getter? done : Bool

      # The original unmodified progress line.
      getter raw : String

      def initialize(@task, @raw, @current = nil, @total = nil, @percent = nil, @done = false)
      end

      # Parses one progress line into a `ProgressMessage`. Never raises — unrecognised
      # lines produce a message with `task == raw` and all numeric fields nil.
      def self.parse(line : String) : ProgressMessage
        if m = line.match(/^(.+?):\s*(\d+)%\s*\((\d+)\/(\d+)\)(.*)/)
          new(m[1].strip, line, m[3].to_i, m[4].to_i, m[2].to_i, m[5].includes?("done"))
        elsif m = line.match(/^(.+?):\s*(\d+),\s*done\.\s*$/)
          new(m[1].strip, line, m[2].to_i, done: true)
        else
          new(line, line)
        end
      end
    end

    # Callback invoked once per completed progress line during `Git.clone` or `Git.pull`.
    # Each invocation delivers a parsed `ProgressMessage` rather than raw bytes.
    alias ProgressCallback = ProgressMessage ->

    # Buffers raw git sideband channel-2 bytes, splits on newlines, strips `\r`-based
    # partial updates (taking only the last overwrite per line), parses each clean line,
    # and delivers it to the callback. Internal use only.
    private class ProgressLineBuffer
      def initialize(@callback : ProgressCallback)
        @buf = IO::Memory.new
      end

      def write(data : Bytes) : Nil
        @buf.write(data)
        content = String.new(@buf.to_slice)
        last_nl = content.rindex('\n')
        return unless last_nl

        content[0, last_nl].split('\n').each do |segment|
          # git uses \r to overwrite the same terminal line with incremental updates;
          # the last \r-separated segment is the final (most complete) value.
          clean = segment.split('\r').last.strip
          @callback.call(ProgressMessage.parse(clean)) unless clean.empty?
        end

        tail = content[last_nl + 1..]
        @buf = IO::Memory.new
        @buf.write(tail.to_slice) unless tail.empty?
      end
    end
  end
end
