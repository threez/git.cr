require "../../spec_helper"

describe Git::Pack::Index do
  describe ".read_count" do
    it "reads the correct object count from an index file" do
      objects = [
        {Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, "a".to_slice), Git::Pack::ObjectType::Blob, "a".to_slice},
        {Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, "bb".to_slice), Git::Pack::ObjectType::Blob, "bb".to_slice},
        {Git::Pack::Delta.git_sha1(Git::Pack::ObjectType::Blob, "ccc".to_slice), Git::Pack::ObjectType::Blob, "ccc".to_slice},
      ]

      dir = spec_tmp("idx-spec")
      Dir.mkdir_p(dir)
      begin
        pack_path = File.join(dir, "pack-test.pack")
        write_spec_pack(pack_path, objects)
        resolver = Git::Pack::Resolver.new(pack_path, objects.size)
        resolver.resolve!
        idx_path = Git::Pack::IndexWriter.write_for_pack(resolver.sha1_map.values, pack_path)

        Git::Pack::Index.read_count(idx_path).should eq(3)
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
