require "../../spec_helper"
require "file_utils"

describe Git::Repository::LockFile do
  tmp = uninitialized String

  around_each do |example|
    tmp = spec_tmp("lockfile-spec")
    Dir.mkdir_p(tmp)
    example.run
    FileUtils.rm_rf(tmp)
  end

  describe ".write" do
    it "creates the target file with correct content" do
      path = File.join(tmp, "HEAD")
      Git::Repository::LockFile.write(path, &.print("ref: refs/heads/main\n"))
      File.read(path).should eq("ref: refs/heads/main\n")
    end

    it "removes the .lock file after a successful write" do
      path = File.join(tmp, "HEAD")
      Git::Repository::LockFile.write(path, &.print("ref: refs/heads/main\n"))
      File.exists?(path + ".lock").should be_false
    end

    it "commits multiple print calls as a single atomic file" do
      path = File.join(tmp, "packed-refs")
      Git::Repository::LockFile.write(path) do |io|
        io.print("# pack-refs\n")
        io.print("abc123 refs/heads/main\n")
      end
      File.read(path).should eq("# pack-refs\nabc123 refs/heads/main\n")
    end

    it "raises LockError when the .lock file already exists" do
      path = File.join(tmp, "HEAD")
      File.write(path + ".lock", "stale")
      expect_raises(Git::LockError) do
        Git::Repository::LockFile.write(path, &.print("data\n"))
      end
    end

    it "LockError message includes the lock file path" do
      path = File.join(tmp, "HEAD")
      File.write(path + ".lock", "stale")
      ex = expect_raises(Git::LockError) do
        Git::Repository::LockFile.write(path, &.print("data\n"))
      end
      ex.message.to_s.should contain(path + ".lock")
    end

    it "cleans up the lock file when the block raises an exception" do
      path = File.join(tmp, "HEAD")
      expect_raises(Exception) do
        Git::Repository::LockFile.write(path) { |_io| raise "boom" }
      end
      File.exists?(path + ".lock").should be_false
    end

    it "does not create the target file when the block raises" do
      path = File.join(tmp, "HEAD")
      expect_raises(Exception) do
        Git::Repository::LockFile.write(path) { |_io| raise "boom" }
      end
      File.exists?(path).should be_false
    end

    it "succeeds after manually removing a stale lock file" do
      path = File.join(tmp, "HEAD")
      File.write(path + ".lock", "stale")
      expect_raises(Git::LockError) { Git::Repository::LockFile.write(path, &.print("first\n")) }
      File.delete(path + ".lock")
      Git::Repository::LockFile.write(path, &.print("second\n"))
      File.read(path).should eq("second\n")
    end

    it "raises File::Error (not LockError) when the parent directory does not exist" do
      path = File.join(tmp, "nonexistent", "HEAD")
      expect_raises(File::Error) do
        Git::Repository::LockFile.write(path, &.print("data\n"))
      end
    end
  end
end
