require "compress/zlib"

module Git
  # In-memory index of all objects across every pack file and loose object in a repository.
  # Loads all `.pack`/`.idx` pairs from `objects/pack/` and all loose objects from
  # `objects/<xx>/<38-hex>` at construction time. Pack objects take precedence when
  # the same OID appears in both forms (standard git behaviour).
  # Used for thin-pack resolution (`Pack::Resolver`) and ancestry checking (`CommitGraph`).
  class Object::Store < Object::BlobSource
    def initialize(repo : Repository)
      @objects = Hash(Id, {Pack::ObjectType, Bytes}).new
      load_packs(repo.objects_pack_dir, repo.git_dir)
      load_loose_objects(repo.git_dir.join("objects"), repo.git_dir)
    end

    def initialize(@objects : Hash(Id, {Pack::ObjectType, Bytes}))
    end

    # Looks up *sha1* in the local pack store. Returns `{type, data}` or nil if unknown.
    def [](oid : Id) : {Pack::ObjectType, Bytes}?
      @objects[oid]?
    end

    # Looks up *oid* in *extra* first, then in the local pack store.
    # This is the canonical lookup pattern for freshly fetched objects that may not be indexed yet.
    def fetch(oid : Id, extra : Pack::Resolver? = nil) : {Pack::ObjectType, Bytes}?
      extra.try(&.[](oid)) || @objects[oid]?
    end

    # Returns true if *sha1* is known to this store (without loading object data).
    def includes?(sha1 : Id) : Bool
      @objects.has_key?(sha1)
    end

    # Returns all SHA-1 ids known to this store.
    def sha1s : Array(Id)
      @objects.keys
    end

    private def load_packs(pack_dir : String, fs : FileSystem = FileSystem::Local.new) : Nil
      fs.glob(File.join(pack_dir, "*#{Pack::PACK_EXT}")).each do |pack_path|
        idx_path = pack_path.sub(/\.pack$/, Pack::IDX_EXT)
        next unless fs.file?(idx_path)
        count = Pack::Index.read_count(idx_path, fs)
        next if count == 0
        resolver = Pack::Resolver.new(pack_path, count, fs)
        resolver.resolve!
        resolver.sha1_map.each do |sha1, obj|
          @objects[sha1] ||= {obj.type, obj.data}
        end
      end
    end

    private def load_loose_objects(objects_dir : String, fs : FileSystem = FileSystem::Local.new) : Nil
      return unless fs.directory?(objects_dir)
      fs.glob(File.join(objects_dir, "??", "*")).each do |path|
        parts = path.split(File::SEPARATOR)
        hex = parts[-2] + parts[-1]
        next unless hex.size == 40 && hex.matches?(/\A[0-9a-f]{40}\z/)
        oid = Id.from_hex(hex)
        next if @objects.has_key?(oid)
        @objects[oid] = read_loose_object(path, fs)
      end
    end

    private def read_loose_object(path : String, fs : FileSystem = FileSystem::Local.new) : {Pack::ObjectType, Bytes}
      compressed = IO::Memory.new(fs.read(path).to_slice)
      raw = Compress::Zlib::Reader.open(compressed, &.getb_to_end)
      nul = raw.index(0_u8) || raise RepositoryError.new("Corrupt loose object: no NUL in header at #{path}")
      header = String.new(raw[0, nul])
      body = raw[nul + 1..]
      type_str, _size = header.split(' ', 2)
      type = case type_str
             when "commit" then Pack::ObjectType::Commit
             when "tree"   then Pack::ObjectType::Tree
             when "blob"   then Pack::ObjectType::Blob
             when "tag"    then Pack::ObjectType::Tag
             else               raise RepositoryError.new("Unknown loose object type #{type_str.inspect} at #{path}")
             end
      {type, body}
    end
  end
end
