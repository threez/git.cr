module Git
  module Worktree
    # Applies the diff between two commits to a working tree in one step.
    # Combines Diff + Checkout so callers don't have to orchestrate both.
    module Applier
      # Diffs the trees of *from_oid* and *to_oid*, applies all file-level
      # changes to *work_dir*, and resolves LFS pointers if *lfs_client* is given.
      # Returns the flat list of changes for downstream use (e.g. submodule updates).
      def self.apply(
        work_dir : FileSystem,
        from_oid : Object::Id,
        to_oid : Object::Id,
        source : Object::BlobSource,
        lfs_client : LFS::Client? = nil,
      ) : Array(Change)
        from_result = source[from_oid] || raise Error.new("Commit #{from_oid.to_hex} not found")
        to_result = source[to_oid] || raise Error.new("Commit #{to_oid.to_hex} not found")
        from_commit = Object::Commit.parse(from_result[1])
        to_commit = Object::Commit.parse(to_result[1])
        changes = Diff.diff(from_commit.tree, to_commit.tree, source)
        Checkout.apply_changes(work_dir, source, changes, lfs_client: lfs_client)
        changes
      end
    end
  end
end
