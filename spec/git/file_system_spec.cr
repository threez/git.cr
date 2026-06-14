require "../spec_helper"

private def tmp_dir(prefix : String) : String
  path = spec_tmp("#{prefix}")
  Dir.mkdir_p(path)
  path
end

describe Git::FileSystem::Guarded do
  it "allows read/write within root" do
    root = tmp_dir("fs-guarded")
    begin
      fs = Git::FileSystem::Guarded.new(root)
      path = File.join(root, "hello.txt")
      fs.write(path, "world")
      fs.read(path).should eq("world")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "raises on path that escapes root via .." do
    root = tmp_dir("fs-guarded")
    begin
      fs = Git::FileSystem::Guarded.new(root)
      escape = File.join(root, "..", "etc", "passwd")
      expect_raises(Git::Error, /escapes root/) do
        fs.read(escape)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "raises on absolute path outside root" do
    root = tmp_dir("fs-guarded")
    begin
      fs = Git::FileSystem::Guarded.new(root)
      expect_raises(Git::Error, /escapes root/) do
        fs.write("/tmp/evil-#{Random::Secure.hex(4)}.txt", "bad")
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "raises when a parent directory is a symlink" do
    root = tmp_dir("fs-guarded")
    outside = tmp_dir("fs-outside")
    begin
      link = File.join(root, "link")
      File.symlink(outside, link)
      fs = Git::FileSystem::Guarded.new(root)
      expect_raises(Git::Error, /[Ss]ymlink/) do
        fs.write(File.join(link, "escape.txt"), "bad")
      end
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(outside)
    end
  end

  it "allows mkdir_p and exists? within root" do
    root = tmp_dir("fs-guarded")
    begin
      fs = Git::FileSystem::Guarded.new(root)
      sub = File.join(root, "a", "b", "c")
      fs.mkdir_p(sub)
      fs.exists?(sub).should be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "raises mkdir_p outside root" do
    root = tmp_dir("fs-guarded")
    begin
      fs = Git::FileSystem::Guarded.new(root)
      expect_raises(Git::Error, /escapes root/) do
        fs.mkdir_p("/tmp/outside_#{Random::Secure.hex(4)}")
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "raises when writing through a leaf symlink pointing outside root" do
    root = tmp_dir("fs-guarded")
    outside = tmp_dir("fs-outside")
    begin
      link = File.join(root, "escape.txt")
      File.symlink(File.join(outside, "target.txt"), link)
      fs = Git::FileSystem::Guarded.new(root)
      expect_raises(Git::Error, /[Ss]ymlink/) do
        fs.write(link, "bad")
      end
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(outside)
    end
  end

  it "allows deleting a symlink inside root" do
    root = tmp_dir("fs-guarded")
    outside = tmp_dir("fs-outside")
    begin
      link = File.join(root, "link.txt")
      File.symlink(File.join(outside, "target.txt"), link)
      fs = Git::FileSystem::Guarded.new(root)
      fs.delete(link)
      File.exists?(link).should be_false
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(outside)
    end
  end

  it "raises cd into a symlinked directory pointing outside root" do
    root = tmp_dir("fs-guarded")
    outside = tmp_dir("fs-outside")
    begin
      link = File.join(root, "subdir")
      File.symlink(outside, link)
      fs = Git::FileSystem::Guarded.new(root)
      expect_raises(Git::Error, /[Ss]ymlink/) do
        fs.chroot("subdir")
      end
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(outside)
    end
  end
end

describe Git::FileSystem::Local do
  it "reads and writes files" do
    root = tmp_dir("fs-local")
    begin
      fs = Git::FileSystem::Local.new
      path = File.join(root, "test.txt")
      fs.write(path, "hello")
      fs.read(path).should eq("hello")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reports exists? correctly" do
    root = tmp_dir("fs-local")
    begin
      fs = Git::FileSystem::Local.new
      path = File.join(root, "x.txt")
      fs.exists?(path).should be_false
      fs.write(path, "")
      fs.exists?(path).should be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
