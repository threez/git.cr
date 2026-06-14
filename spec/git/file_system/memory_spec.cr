require "../../spec_helper"

describe Git::FileSystem::Memory do
  describe "read / write" do
    it "round-trips a string" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("hello.txt", "world")
      fs.read("hello.txt").should eq("world")
    end

    it "round-trips bytes" do
      fs = Git::FileSystem::Memory.new("/mock")
      data = Bytes[1, 2, 3, 4]
      fs.write("bin.dat", data)
      fs.read("bin.dat").to_slice.should eq(data)
    end

    it "raises File::NotFoundError on missing path" do
      fs = Git::FileSystem::Memory.new("/mock")
      expect_raises(File::NotFoundError) { fs.read("missing.txt") }
    end

    it "overwrites existing content" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("f.txt", "first")
      fs.write("f.txt", "second")
      fs.read("f.txt").should eq("second")
    end
  end

  describe "exists? / file? / directory?" do
    it "returns false for missing path" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.exists?("nope.txt").should be_false
      fs.file?("nope.txt").should be_false
      fs.directory?("nope.txt").should be_false
    end

    it "exists? and file? are true after write" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("a.txt", "x")
      fs.exists?("a.txt").should be_true
      fs.file?("a.txt").should be_true
      fs.directory?("a.txt").should be_false
    end

    it "exists? and directory? are true after mkdir_p" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.mkdir_p("sub/dir")
      fs.exists?("sub/dir").should be_true
      fs.directory?("sub/dir").should be_true
      fs.file?("sub/dir").should be_false
    end
  end

  describe "mkdir_p / dir_empty? / rmdir" do
    it "creates nested directories" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.mkdir_p("a/b/c")
      fs.directory?("a/b/c").should be_true
      fs.directory?("a/b").should be_true
      fs.directory?("a").should be_true
    end

    it "dir_empty? is true for an empty dir" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.mkdir_p("empty")
      fs.dir_empty?("empty").should be_true
    end

    it "dir_empty? is false when a file exists underneath" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("notempty/file.txt", "x")
      fs.dir_empty?("notempty").should be_false
    end

    it "rmdir removes an empty directory" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.mkdir_p("rmme")
      fs.rmdir("rmme")
      fs.directory?("rmme").should be_false
    end

    it "rmdir raises when directory is not empty" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("has/file.txt", "x")
      expect_raises(File::Error) { fs.rmdir("has") }
    end
  end

  describe "delete" do
    it "removes a file" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("del.txt", "bye")
      fs.delete("del.txt")
      fs.exists?("del.txt").should be_false
    end

    it "raises File::NotFoundError on missing file" do
      fs = Git::FileSystem::Memory.new("/mock")
      expect_raises(File::NotFoundError) { fs.delete("ghost.txt") }
    end
  end

  describe "rm_rf" do
    it "removes a file" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("bye.txt", "x")
      fs.rm_rf("bye.txt")
      fs.exists?("bye.txt").should be_false
    end

    it "recursively removes a directory tree" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("tree/a.txt", "1")
      fs.write("tree/sub/b.txt", "2")
      fs.rm_rf("tree")
      fs.exists?("tree/a.txt").should be_false
      fs.exists?("tree/sub/b.txt").should be_false
      fs.directory?("tree").should be_false
    end

    it "silently succeeds when path does not exist" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.rm_rf("nonexistent")
    end
  end

  describe "rename" do
    it "moves a file" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("old.txt", "data")
      fs.rename("old.txt", "new.txt")
      fs.exists?("old.txt").should be_false
      fs.read("new.txt").should eq("data")
    end
  end

  describe "symlink / symlink?" do
    it "records a symlink" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.symlink("../target", "link.txt")
      fs.symlink?("link.txt").should be_true
      fs.symlink?("missing.txt").should be_false
    end

    it "delete removes a symlink" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.symlink("target", "lnk")
      fs.delete("lnk")
      fs.symlink?("lnk").should be_false
    end
  end

  describe "size" do
    it "returns byte size of stored content" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("f.txt", "hello")
      fs.size("f.txt").should eq(5_i64)
    end
  end

  describe "read_lines" do
    it "splits content into lines" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("lines.txt", "a\nb\nc")
      fs.read_lines("lines.txt").should eq(["a", "b", "c"])
    end
  end

  describe "glob" do
    it "matches files with **/* pattern" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("a.txt", "")
      fs.write("sub/b.txt", "")
      fs.write("sub/deep/c.txt", "")
      result = fs.glob("/mock/**/*")
      result.should contain("/mock/a.txt")
      result.should contain("/mock/sub/b.txt")
      result.should contain("/mock/sub/deep/c.txt")
    end
  end

  describe "chroot" do
    it "returns a FileSystem::Memory rooted at the subdirectory" do
      fs = Git::FileSystem::Memory.new("/mock")
      sub = fs.chroot("sub")
      sub.should be_a(Git::FileSystem::Memory)
      sub.root.should eq("/mock/sub")
    end

    it "shares underlying storage with the parent" do
      fs = Git::FileSystem::Memory.new("/mock")
      sub = fs.chroot("sub")
      sub.write("file.txt", "from child")
      fs.read("sub/file.txt").should eq("from child")
    end

    it "write in parent is visible in child" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("sub/file.txt", "from parent")
      sub = fs.chroot("sub")
      sub.read("file.txt").should eq("from parent")
    end
  end

  describe "open" do
    it "wb / rb round-trips binary data" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.open("pack.bin", "wb") do |io|
        io.write(Bytes[0x50, 0x41, 0x43, 0x4b]) # "PACK"
        io.write_bytes(2_u32, IO::ByteFormat::BigEndian)
      end
      fs.open("pack.bin", "rb") do |io|
        buf = Bytes.new(4)
        io.read_fully(buf)
        String.new(buf).should eq("PACK")
        count_buf = Bytes.new(4)
        io.read_fully(count_buf)
        IO::ByteFormat::BigEndian.decode(UInt32, count_buf).should eq(2_u32)
      end
    end

    it "r+b allows seek-and-overwrite" do
      fs = Git::FileSystem::Memory.new("/mock")
      fs.write("data.bin", Bytes[1, 2, 3, 4, 5, 6, 7, 8])
      fs.open("data.bin", "r+b") do |io|
        io.seek(-4, IO::Seek::End)
        io.write(Bytes[0xAA, 0xBB, 0xCC, 0xDD])
      end
      result = fs.read("data.bin").to_slice
      result.should eq(Bytes[1, 2, 3, 4, 0xAA, 0xBB, 0xCC, 0xDD])
    end

    it "rb raises File::NotFoundError for missing file" do
      fs = Git::FileSystem::Memory.new("/mock")
      expect_raises(File::NotFoundError) { fs.open("missing.bin", "rb") { } }
    end
  end
end
