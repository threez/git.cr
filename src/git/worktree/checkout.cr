module Git
  module Worktree
    # Writes and updates a working tree from git object data.
    module Checkout
      # Checks out the working tree for the commit at head_oid into work_dir.
      # If *lfs_client* is provided, LFS pointer blobs are replaced with real content.
      # *file_system* defaults to a `FileSystem::Guarded` rooted at *work_dir*,
      # ensuring no tree entry can write outside the checkout root.
      def self.run(
        source : Object::BlobSource,
        head_oid : Object::Id,
        work_dir : FileSystem,
        lfs_client : LFS::Client? = nil,
        file_system : FileSystem? = nil,
      ) : Nil
        fs = file_system || FileSystem::Guarded.new(work_dir.root)
        type_data = source[head_oid] || raise Error.new("HEAD commit #{head_oid} not found in packfile")
        type, commit_data = type_data
        raise Error.new("Expected commit at HEAD, got #{type}") unless type.commit?

        commit = Object::Commit.parse(commit_data)
        written = [] of String
        checkout_tree(source, commit.tree, work_dir.root, written, work_dir.root, fs)
        resolve_lfs(written, lfs_client, fs) if lfs_client
      end

      # Applies a pre-computed list of `Change`s to *work_dir*.
      # More efficient than `run` for incremental updates (e.g. after a pull)
      # because it only touches files that actually changed.
      # If *lfs_client* is provided, LFS pointer blobs are replaced with real content.
      # *file_system* defaults to a `FileSystem::Guarded` rooted at *work_dir*.
      def self.apply_changes(
        work_dir : FileSystem,
        source : Object::BlobSource,
        changes : Array(Change),
        lfs_client : LFS::Client? = nil,
        file_system : FileSystem? = nil,
      ) : Nil
        fs = file_system || FileSystem::Guarded.new(work_dir.root)
        written = [] of String
        changes.each do |change|
          path = fs.join(change.path)
          case change.kind
          when Change::Kind::Deleted
            if fs.exists?(path)
              fs.file?(path) ? fs.delete(path) : fs.rm_rf(path)
            end
            try_rmdir_parents(path, fs.root, fs)
          when Change::Kind::Added, Change::Kind::Modified
            next if change.mode == 0o160000_u32
            fs.mkdir_p(File.dirname(path))
            oid = change.oid.not_nil! # ameba:disable Lint/NotNil
            result = source[oid]
            raise Error.new("Blob #{oid.to_hex} not found") unless result
            fs.delete(path) if fs.symlink?(path)
            fs.write(path, result[1])
            fs.chmod(path, change.mode & 0o111_u32 != 0 ? 0o755 : 0o644)
            written << path
          end
        end
        resolve_lfs(written, lfs_client, fs) if lfs_client
      end

      # Scans all files under *work_dir* for LFS pointer blobs and resolves them.
      # Used for file:// clones where .lfsconfig is only readable after initial checkout.
      def self.resolve_lfs_dir(
        work_dir : FileSystem,
        lfs_client : LFS::Client,
        file_system : FileSystem? = nil,
      ) : Nil
        fs = file_system || FileSystem::Guarded.new(work_dir.root)
        paths = fs.glob(fs.join("**", "*")).select { |path| fs.file?(path) }
        resolve_lfs(paths, lfs_client, fs)
      end

      private def self.try_rmdir_parents(path : String, stop_at : String, file_system : FileSystem) : Nil
        dir = File.dirname(path)
        stop_prefix = stop_at.ends_with?(File::SEPARATOR_STRING) ? stop_at : stop_at + File::SEPARATOR_STRING
        while dir != stop_at && dir.starts_with?(stop_prefix)
          break unless file_system.dir_empty?(dir)
          file_system.rmdir(dir)
          dir = File.dirname(dir)
        end
      end

      private def self.checkout_tree(
        source : Object::BlobSource,
        tree_oid : Object::Id,
        dir : String,
        written : Array(String),
        work_dir : String,
        file_system : FileSystem,
      ) : Nil
        file_system.mkdir_p(dir)

        type_data = source[tree_oid] || raise Error.new("Tree #{tree_oid} not found in packfile")
        _, tree_data = type_data

        Object::Tree.parse(tree_data).each do |entry|
          path = File.join(dir, entry.name)

          if entry.directory?
            checkout_tree(source, entry.oid, path, written, work_dir, file_system)
          elsif entry.gitlink?
            file_system.mkdir_p(path)
          elsif entry.symlink?
            blob_td = source[entry.oid] || raise Error.new("Symlink blob #{entry.oid} not found")
            _, blob_data = blob_td
            file_system.symlink(String.new(blob_data), path)
          else
            blob_td = source[entry.oid] || raise Error.new("Blob #{entry.oid} not found")
            _, blob_data = blob_td
            file_system.delete(path) if file_system.symlink?(path)
            file_system.write(path, blob_data)
            file_system.chmod(path, entry.executable? ? 0o755 : 0o644)
            written << path
          end
        end
      end

      private def self.resolve_lfs(paths : Array(String), lfs_client : LFS::Client, file_system : FileSystem) : Nil
        pointers = {} of String => LFS::Pointer
        paths.each do |abs_path|
          next unless file_system.file?(abs_path)
          next if file_system.size(abs_path) > 200
          data = file_system.read(abs_path).to_slice
          if pointer = LFS::Pointer.parse?(data)
            pointers[abs_path] = pointer
          end
        end
        return if pointers.empty?

        deduped = {} of String => LFS::Pointer
        pointers.each_value { |ptr| deduped[ptr.oid] ||= ptr }
        unique_pointers = deduped.values
        batch = lfs_client.fetch_batch(unique_pointers)
        pointers.each do |abs_path, pointer|
          if content = batch[pointer.oid]?
            file_system.write(abs_path, content)
          end
        end
      end
    end
  end
end
