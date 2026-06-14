require "../../spec_helper"

# Builds a sideband-64k framed pkt-line stream.
# Each chunk is: pkt-line containing [channel_byte, ...payload].
private def build_sideband_stream(chunks : Array({UInt8, Bytes}), flush : Bool = true) : IO::Memory
  mem = IO::Memory.new
  w = Git::Protocol::PktLine::Writer.new(mem)
  chunks.each do |channel, payload|
    packet = Bytes.new(1 + payload.size)
    packet[0] = channel
    payload.copy_to(packet + 1)
    w.write_data(packet)
  end
  w.write_flush if flush
  mem.rewind
  mem
end

describe Git::Protocol::SidebandReader do
  it "reads channel-1 data as the packfile stream" do
    payload = "packfile data".to_slice
    stream = build_sideband_stream([{1_u8, payload}])
    reader = Git::Protocol::PktLine::Reader.new(stream)
    sideband = Git::Protocol::SidebandReader.new(reader)

    buf = Bytes.new(payload.size)
    n = sideband.read(buf)
    n.should eq(payload.size)
    buf.should eq(payload)
  end

  it "returns 0 on flush (end of stream)" do
    stream = build_sideband_stream([] of {UInt8, Bytes})
    reader = Git::Protocol::PktLine::Reader.new(stream)
    sideband = Git::Protocol::SidebandReader.new(reader)

    buf = Bytes.new(4)
    sideband.read(buf).should eq(0)
  end

  it "raises ProtocolError for channel-3 error messages" do
    msg = "remote hung up".to_slice
    stream = build_sideband_stream([{3_u8, msg}])
    reader = Git::Protocol::PktLine::Reader.new(stream)
    sideband = Git::Protocol::SidebandReader.new(reader)

    buf = Bytes.new(4)
    expect_raises(Git::ProtocolError, /remote hung up/) { sideband.read(buf) }
  end

  it "delivers channel-2 lines to the on_progress callback" do
    received = [] of Git::Protocol::ProgressMessage
    progress_line = "Counting objects: 5, done.\n".to_slice
    # channel 2 then channel 1 (so the reader has something to return)
    payload = "x".to_slice
    stream = build_sideband_stream([{2_u8, progress_line}, {1_u8, payload}])
    reader = Git::Protocol::PktLine::Reader.new(stream)
    sideband = Git::Protocol::SidebandReader.new(reader,
      on_progress: ->(msg : Git::Protocol::ProgressMessage) { received << msg })

    buf = Bytes.new(payload.size)
    sideband.read(buf)
    received.any?(&.done?).should be_true
  end
end
