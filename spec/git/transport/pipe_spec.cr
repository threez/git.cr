require "../../spec_helper"

# Minimal concrete subclass for testing Transport::Pipe in isolation.
private class TestPipe < Git::Transport::Pipe
  def open : Nil
  end

  def spawn_failing_process : Nil
    spawn_process("sh", ["-c", "exit 1"])
  end

  private def command_name : String
    "test"
  end
end

# Subclass that spawns `cat` — echoes stdin to stdout — for request tests.
private class TestPipeEcho < Git::Transport::Pipe
  def open : Nil
    spawn_process("cat", [] of String)
  end

  private def command_name : String
    "cat"
  end
end

describe Git::Transport::Pipe do
  it "stdin! raises TransportError before open is called" do
    transport = TestPipe.new
    expect_raises(Git::TransportError, /not open/) do
      transport.stdin!
    end
  end

  it "stdout! raises TransportError before open is called" do
    transport = TestPipe.new
    expect_raises(Git::TransportError, /not open/) do
      transport.stdout!
    end
  end

  it "close raises TransportError when subprocess exits with non-zero status" do
    transport = TestPipe.new
    transport.spawn_failing_process
    expect_raises(Git::TransportError, /exit/) do
      transport.close
    end
  end

  describe "#request" do
    it "writes body to stdin and yields stdout" do
      transport = TestPipeEcho.new
      transport.open
      received = ""
      transport.request("ping".to_slice) do |io|
        buf = Bytes.new(4)
        io.read_fully(buf)
        received = String.new(buf)
      end
      transport.close
      received.should eq("ping")
    end
  end
end
