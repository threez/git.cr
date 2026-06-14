require "../../spec_helper"

describe Git::Protocol::CapabilitySet do
  describe ".parse" do
    it "parses flag-style capabilities" do
      caps = Git::Protocol::CapabilitySet.parse("side-band-64k ofs-delta")
      caps.side_band_64k?.should be_true
      caps.ofs_delta?.should be_true
    end

    it "parses key=value capabilities" do
      caps = Git::Protocol::CapabilitySet.parse("agent=git/2.39.0")
      caps.agent.should eq("git/2.39.0")
    end

    it "parses mixed capabilities" do
      caps = Git::Protocol::CapabilitySet.parse("side-band-64k agent=git/2.39.0 ofs-delta")
      caps.side_band_64k?.should be_true
      caps.ofs_delta?.should be_true
      caps.agent.should eq("git/2.39.0")
    end

    it "returns false for absent capabilities" do
      caps = Git::Protocol::CapabilitySet.parse("")
      caps.side_band_64k?.should be_false
      caps.ofs_delta?.should be_false
    end
  end

  describe "#to_want_line_suffix" do
    it "includes side-band-64k when server supports it" do
      caps = Git::Protocol::CapabilitySet.parse("side-band-64k ofs-delta")
      suffix = caps.to_want_line_suffix
      suffix.should contain("side-band-64k")
      suffix.should contain("ofs-delta")
    end

    it "always includes the agent" do
      caps = Git::Protocol::CapabilitySet.parse("")
      caps.to_want_line_suffix.should contain("agent=")
    end

    it "starts with a space" do
      caps = Git::Protocol::CapabilitySet.parse("side-band-64k")
      caps.to_want_line_suffix.should start_with(" ")
    end

    it "omits side-band-64k when server does not advertise it" do
      caps = Git::Protocol::CapabilitySet.parse("ofs-delta")
      caps.to_want_line_suffix.should_not contain("side-band-64k")
    end
  end
end
