require "../../spec_helper"
require "file_utils"
require "digest/sha1"

# Writes a real loose git object file under *git_dir* and returns its ObjectId.
private def write_loose_object(git_dir : String, type_str : String, data : Bytes) : Git::Object::Id
  header = "#{type_str} #{data.size}\0"
  content = header.to_slice + data
  hex = Digest::SHA1.hexdigest(content)
  dir = File.join(git_dir, "objects", hex[0, 2])
  Dir.mkdir_p(dir)
  File.open(File.join(dir, hex[2..]), "wb") do |file|
    Compress::Zlib::Writer.open(file, &.write(content))
  end
  Git.oid(hex)
end

# Returns a minimal git_dir skeleton with the required subdirectories.
private def make_loose_git_dir(base : String) : String
  git_dir = File.join(base, ".git")
  Dir.mkdir_p(File.join(git_dir, "objects", "pack"))
  git_dir
end

describe Git::Object::Store do
  describe "#[]" do
    it "finds an object by SHA1" do
      blob_data = "hello store\n".to_slice
      blob_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, blob_data)

      store = make_spec_store([{blob_oid, Git::Pack::ObjectType::Blob, blob_data}])
      store[blob_oid].should eq({Git::Pack::ObjectType::Blob, blob_data})
    end

    it "returns nil for unknown SHA1" do
      store = make_spec_store([] of {Git::Object::Id, Git::Pack::ObjectType, Bytes})
      store[Git.oid("0000000000000000000000000000000000000000")].should be_nil
    end
  end

  describe "#includes?" do
    it "returns true for a known object" do
      data = "test\n".to_slice
      oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, data)
      store = make_spec_store([{oid, Git::Pack::ObjectType::Blob, data}])
      store.includes?(oid).should be_true
    end

    it "returns false for an unknown object" do
      store = make_spec_store([] of {Git::Object::Id, Git::Pack::ObjectType, Bytes})
      store.includes?(Git.oid("da39a3ee5e6b4b0d3255bfef95601890afd80709")).should be_false
    end
  end

  describe "#sha1s" do
    it "returns all object SHA1s" do
      a_data = "a\n".to_slice
      b_data = "b\n".to_slice
      a_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, a_data)
      b_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, b_data)
      store = make_spec_store([
        {a_oid, Git::Pack::ObjectType::Blob, a_data},
        {b_oid, Git::Pack::ObjectType::Blob, b_data},
      ])
      store.sha1s.size.should eq(2)
      store.sha1s.should contain(a_oid)
      store.sha1s.should contain(b_oid)
    end
  end

  describe "loose objects" do
    tmp = uninitialized String
    around_each do |ex|
      tmp = spec_tmp("loose-store")
      Dir.mkdir_p(tmp)
      ex.run
      FileUtils.rm_rf(tmp)
    end

    it "loads a loose blob and returns the correct type and data" do
      git_dir = make_loose_git_dir(tmp)
      data = "hello loose world\n".to_slice
      oid = write_loose_object(git_dir, "blob", data)

      store = Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      type, body = store[oid] || raise "expected object #{oid} in store"
      type.should eq(Git::Pack::ObjectType::Blob)
      body.should eq(data)
    end

    it "loads a loose commit and returns Commit type" do
      git_dir = make_loose_git_dir(tmp)
      data = "tree #{"0" * 40}\nauthor A <a@b> 0 +0000\n\nInit\n".to_slice
      oid = write_loose_object(git_dir, "commit", data)

      store = Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      type, _ = store[oid] || raise "expected object #{oid} in store"
      type.should eq(Git::Pack::ObjectType::Commit)
    end

    it "loads a loose tree and returns Tree type" do
      git_dir = make_loose_git_dir(tmp)
      oid = write_loose_object(git_dir, "tree", Bytes.new(0))

      store = Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      type, _ = store[oid] || raise "expected object #{oid} in store"
      type.should eq(Git::Pack::ObjectType::Tree)
    end

    it "loads a loose tag and returns Tag type" do
      git_dir = make_loose_git_dir(tmp)
      oid = write_loose_object(git_dir, "tag", "object #{"0" * 40}\n".to_slice)

      store = Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      type, _ = store[oid] || raise "expected object #{oid} in store"
      type.should eq(Git::Pack::ObjectType::Tag)
    end

    it "includes? returns true for a loose object" do
      git_dir = make_loose_git_dir(tmp)
      oid = write_loose_object(git_dir, "blob", "data".to_slice)

      store = Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      store.includes?(oid).should be_true
    end

    it "loads multiple loose objects from different hash directories" do
      git_dir = make_loose_git_dir(tmp)
      oid1 = write_loose_object(git_dir, "blob", "first".to_slice)
      oid2 = write_loose_object(git_dir, "blob", "second".to_slice)

      store = Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      store.includes?(oid1).should be_true
      store.includes?(oid2).should be_true
    end

    it "sha1s includes loose object OIDs" do
      git_dir = make_loose_git_dir(tmp)
      oid = write_loose_object(git_dir, "blob", "tracked".to_slice)

      store = Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      store.sha1s.should contain(oid)
    end

    it "pack object takes precedence when the same OID exists as both pack and loose" do
      git_dir = make_loose_git_dir(tmp)
      pack_data = "from pack".to_slice
      loose_data = "from loose".to_slice

      # The same OID: build it from the pack data content
      pack_oid = Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, pack_data)
      # Write the loose file with different bytes but the *same* path/OID
      # (simulating a corrupt / stale loose object for the same hash)
      dir = File.join(git_dir, "objects", pack_oid.to_hex[0, 2])
      Dir.mkdir_p(dir)
      File.open(File.join(dir, pack_oid.to_hex[2..]), "wb") do |file|
        header = "blob #{loose_data.size}\0"
        Compress::Zlib::Writer.open(file, &.write(header.to_slice + loose_data))
      end

      # Write a pack containing pack_oid with pack_data
      pack_path = File.join(git_dir, "objects", "pack", "pack-test.pack")
      write_spec_pack(pack_path, [{pack_oid, Git::Pack::ObjectType::Blob, pack_data}])
      resolver = Git::Pack::Resolver.new(pack_path, 1)
      resolver.resolve!
      Git::Pack::IndexWriter.write_for_pack(resolver.sha1_map.values, pack_path)

      store = Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      _, body = store[pack_oid] || raise "expected pack object #{pack_oid} in store"
      body.should eq(pack_data)
    end

    it "raises RepositoryError for a loose file with an unknown type header" do
      git_dir = make_loose_git_dir(tmp)
      # Manually write a zlib file with an unsupported type string
      dir = File.join(git_dir, "objects", "ab")
      Dir.mkdir_p(dir)
      path = File.join(dir, "a" * 38)
      File.open(path, "wb") do |file|
        Compress::Zlib::Writer.open(file, &.write("bogus 4\u0000data".to_slice))
      end

      expect_raises(Git::RepositoryError, /Unknown loose object type/) do
        Git::Object::Store.new(Git::Repository.new(Git::FileSystem::Local.new(git_dir)))
      end
    end
  end
end
