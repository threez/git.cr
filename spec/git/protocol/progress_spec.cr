require "../../spec_helper"

describe Git::Protocol::ProgressMessage do
  describe ".parse" do
    it "parses a percentage line with done" do
      msg = Git::Protocol::ProgressMessage.parse("Counting objects: 100% (57/57), done.")
      msg.task.should eq("Counting objects")
      msg.percent.should eq(100)
      msg.current.should eq(57)
      msg.total.should eq(57)
      msg.done?.should be_true
    end

    it "parses an in-progress percentage line" do
      msg = Git::Protocol::ProgressMessage.parse("Counting objects:   1% (1/57)")
      msg.task.should eq("Counting objects")
      msg.percent.should eq(1)
      msg.current.should eq(1)
      msg.total.should eq(57)
      msg.done?.should be_false
    end

    it "parses a percentage line with throughput and done" do
      msg = Git::Protocol::ProgressMessage.parse("Receiving objects: 100% (5/5), 1.23 MiB | 500.00 KiB/s, done.")
      msg.task.should eq("Receiving objects")
      msg.percent.should eq(100)
      msg.current.should eq(5)
      msg.total.should eq(5)
      msg.done?.should be_true
    end

    it "parses a count-only done line" do
      msg = Git::Protocol::ProgressMessage.parse("Enumerating objects: 5, done.")
      msg.task.should eq("Enumerating objects")
      msg.current.should eq(5)
      msg.total.should be_nil
      msg.percent.should be_nil
      msg.done?.should be_true
    end

    it "parses a free-form line" do
      msg = Git::Protocol::ProgressMessage.parse("Total 160126 (delta 22), reused 16 (delta 11), pack-reused 160069 (from 2)")
      msg.task.should eq("Total 160126 (delta 22), reused 16 (delta 11), pack-reused 160069 (from 2)")
      msg.current.should be_nil
      msg.total.should be_nil
      msg.percent.should be_nil
      msg.done?.should be_false
      msg.raw.should eq(msg.task)
    end

    it "preserves the raw line" do
      line = "Compressing objects: 100% (46/46), done."
      msg = Git::Protocol::ProgressMessage.parse(line)
      msg.raw.should eq(line)
    end
  end
end
