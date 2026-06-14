module Git
  # Shared base for process-based transports (SSH and `file://`).
  # Manages the subprocess lifecycle; subclasses implement `open` via `spawn_process`.
  abstract class Transport::Pipe < Transport::Base
    @process : Process?
    @stdin : IO::FileDescriptor?
    @stdout : IO::FileDescriptor?
    @stderr : IO::FileDescriptor?

    def close : Nil
      @stdin.try &.close
      proc = @process
      return unless proc
      status = proc.wait
      unless status.success?
        err = begin
          @stderr.try(&.gets_to_end).try(&.strip) || ""
        rescue IO::Error
          ""
        end
        raise TransportError.new("#{command_name} failed (exit #{status.exit_code}): #{err}")
      end
    end

    # Returns the writable subprocess stdin. Raises `TransportError` if `open` was not called.
    def stdin! : IO::FileDescriptor
      @stdin || raise TransportError.new("#{command_name} transport not open — call open first")
    end

    # Returns the readable subprocess stdout. Raises `TransportError` if `open` was not called.
    def stdout! : IO::FileDescriptor
      @stdout || raise TransportError.new("#{command_name} transport not open — call open first")
    end

    def request(body : Bytes, &blk : IO ->) : Nil
      stdin!.write(body)
      stdin!.flush
      blk.call(stdout!)
    end

    def handshake_io : IO
      stdout!
    end

    def stateless? : Bool
      false
    end

    protected def spawn_process(
      command : String,
      args : Array(String),
      env : Hash(String, String)? = nil,
    ) : Nil
      proc = Process.new(command, args: args,
        env: env,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)
      @process = proc
      @stdin = proc.input
      @stdout = proc.output
      @stderr = proc.error
    end

    private abstract def command_name : String
  end
end
