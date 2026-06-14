module Git
  class Client
    # Clones the repository at *url* into the local directory *into*.
    # Returns the initialised `Repository` on success.
    #
    # This is the canonical implementation; `Git.clone` delegates here.
    # See `Git.clone` for full parameter documentation.
    #
    # ### Parameters
    #
    # *git_dir* — Stores the git metadata at a path separate from the working
    # tree (equivalent to `git clone --separate-git-dir`). When set, a plain
    # `.git` file is written inside *into* containing `gitdir: <git_dir>`, and
    # all git objects, refs, and config are placed at *git_dir* instead. Pass
    # `nil` (the default) for the conventional `.git/` subdirectory layout.
    # This is only available through `Client.clone`; `Git.clone` always uses
    # the conventional layout.
    def self.clone(
      url : String,
      into : FileSystem,
      branch : String = "HEAD",
      on_progress : Protocol::ProgressCallback? = nil,
      lfs : Bool = true,
      submodules : Bool = true,
      depth : Int32? = nil,
      credentials : Transport::Credentials? = nil,
      git_dir : FileSystem? = nil,
    ) : Repository
      remote = Git.remote(url)
      repo = Repository.init(into, git_dir)
      clone_with_transport(remote, repo, url, into, branch, on_progress, lfs, submodules, depth, credentials)
      repo
    end

    # Fetches the latest commits from origin and fast-forward merges the tracked
    # branch in the repository at *path*. Returns the updated `Repository`.
    # Raises `NonFastForwardError` when the remote history has diverged.
    # See `Git.pull` for full parameter documentation.
    def self.pull(
      path : FileSystem,
      branch : String = "HEAD",
      on_progress : Protocol::ProgressCallback? = nil,
      lfs : Bool = true,
      submodules : Bool = true,
      credentials : Transport::Credentials? = nil,
    ) : Repository
      fetch_and_apply(path, branch, on_progress, fast_forward_only: true, lfs: lfs, submodules: submodules, credentials: credentials)
    end

    # Fetches the latest commits from origin and hard-resets the local branch and
    # working tree to match, regardless of ancestry. Returns the updated `Repository`.
    # `ORIG_HEAD` is written before the reset so the previous tip can be recovered.
    # See `Git.reset` for full parameter documentation.
    def self.reset(
      path : FileSystem,
      branch : String = "HEAD",
      on_progress : Protocol::ProgressCallback? = nil,
      lfs : Bool = true,
      submodules : Bool = true,
      credentials : Transport::Credentials? = nil,
    ) : Repository
      fetch_and_apply(path, branch, on_progress, fast_forward_only: false, lfs: lfs, submodules: submodules, credentials: credentials)
    end

    # Fetches and applies the latest remote state unconditionally: fast-forwards
    # when possible, hard-resets otherwise. Never raises `NonFastForwardError`.
    # See `Git.sync` for full parameter documentation.
    def self.sync(
      path : FileSystem,
      branch : String = "HEAD",
      on_progress : Protocol::ProgressCallback? = nil,
      lfs : Bool = true,
      submodules : Bool = true,
      credentials : Transport::Credentials? = nil,
    ) : Repository
      reset(path, branch, on_progress, lfs: lfs, submodules: submodules, credentials: credentials)
    end

    private def self.fetch_and_apply(
      path : FileSystem,
      branch : String,
      on_progress : Protocol::ProgressCallback?,
      fast_forward_only : Bool,
      lfs : Bool,
      submodules : Bool,
      credentials : Transport::Credentials? = nil,
    ) : Repository
      repo = Repository.open(path)
      config = Repository::Config.read(repo)
      remote = Git.remote(config.remote_url)

      current = branch == "HEAD" ? repo.current_branch : branch
      local_tip = repo.branch_tip(current)

      store = Object::Store.new(repo)
      existing_shallows = repo.read_shallow

      new_pack = repo.new_packfile_path
      refs, new_resolver, new_shallows, unshallowed = pull_with_transport(
        remote, store, local_tip, current, new_pack, on_progress, existing_shallows, credentials
      )

      target = refs.find { |ref| ref.branch? && ref.branch_name == current } ||
               raise Error.new("Branch #{current.inspect} not found on remote")

      return repo if target.oid == local_tip

      graph = CommitGraph::Chain.load(repo.git_dir.root)
      check_fast_forward!(target.oid, local_tip, store, new_resolver, graph, existing_shallows, fast_forward_only)

      lfs_client = lfs ? lfs_client_for(remote, path, credentials) : nil
      changes = apply_tree_diff(path, local_tip, target.oid, store, new_resolver, lfs_client)

      repo.write_orig_head(local_tip)
      repo.write_branch(current, target.oid)
      repo.write_tracking_ref("origin", current, target.oid)
      repo.write_fetch_head(target.oid, current, config.remote_url)

      reflog_msg = fast_forward_only ? "pull: Fast-forward" : "reset: moving to origin/#{current}"
      repo.append_reflog("refs/heads/#{current}", local_tip, target.oid, reflog_msg)
      repo.append_reflog("refs/remotes/origin/#{current}", local_tip, target.oid, reflog_msg)
      repo.append_reflog("HEAD", local_tip, target.oid, reflog_msg)

      update_shallow_file(repo, existing_shallows, new_shallows, unshallowed)
      if submodules
        clone_sub = ->(sub_url : String, sub_dir : String) {
          Client.clone(sub_url, Git.fs(sub_dir), on_progress: on_progress, lfs: lfs, submodules: true, credentials: credentials)
          nil
        }
        reset_sub = ->(sub_dir : String) {
          Client.reset(Git.fs(sub_dir), on_progress: on_progress, lfs: lfs, submodules: true, credentials: credentials)
          nil
        }
        Repository::Submodule.update_all(path.root, repo.git_dir.root, remote, changes, lfs, on_progress, credentials, clone_sub, reset_sub)
      end

      repo
    end

    private def self.apply_tree_diff(
      work_dir : FileSystem,
      local_tip : Object::Id,
      target_oid : Object::Id,
      store : Object::Store,
      new_resolver : Pack::Resolver,
      lfs_client : LFS::Client?,
    ) : Array(Worktree::Change)
      source = Object::BlobSource.compose(new_resolver, store)
      Worktree::Applier.apply(work_dir, local_tip, target_oid, source, lfs_client)
    end

    private def self.check_fast_forward!(
      target_oid : Object::Id,
      local_tip : Object::Id,
      store : Object::Store,
      new_resolver : Pack::Resolver,
      graph : CommitGraph::Chain?,
      existing_shallows : Array(Object::Id),
      fast_forward_only : Bool,
    ) : Nil
      return unless fast_forward_only && existing_shallows.empty?
      unless CommitGraph.ancestor?(target_oid, local_tip, store, new_resolver, graph)
        raise NonFastForwardError.new("Cannot pull: not a fast-forward. Local branch has diverged.")
      end
    end

    private def self.update_shallow_file(
      repo : Repository,
      existing_shallows : Array(Object::Id),
      new_shallows : Array(Object::Id),
      unshallowed : Array(Object::Id),
    ) : Nil
      return if existing_shallows.empty? && new_shallows.empty?
      repo.write_shallow((existing_shallows + new_shallows - unshallowed).uniq)
    end

    private def self.lfs_client_for(remote : Transport::RemoteURL, path : FileSystem, credentials : Transport::Credentials?) : LFS::Client?
      if remote.http?
        LFS::Client.new(remote, credentials)
      elsif remote.ssh?
        LFS::Client.for_ssh(remote)
      else
        LFS::Client.from_lfs_config?(path.root)
      end
    end

    private def self.clone_with_transport(
      remote : Transport::RemoteURL,
      repo : Repository,
      url : String,
      into : FileSystem,
      branch : String,
      on_progress : Protocol::ProgressCallback?,
      lfs : Bool,
      submodules : Bool,
      depth : Int32?,
      credentials : Transport::Credentials?,
    ) : Nil
      transport = Transport.for(remote, credentials)
      session = Protocol::Negotiator.open(transport)
      refs, target, clone_shallows, object_count = run_clone_fetch(session, repo.packfile_path, depth, branch, on_progress)

      lfs_client = lfs && !transport.needs_post_checkout_lfs? ? lfs_client_for(remote, into, credentials) : nil
      commit_oid = index_and_checkout(repo, target, into, object_count, lfs_client)

      if lfs && transport.needs_post_checkout_lfs?
        if client = lfs_client_for(remote, into, credentials)
          Worktree::Checkout.resolve_lfs_dir(into, client)
        end
      end

      finalize_repo(repo, refs, target, url, commit_oid)
      repo.write_shallow(clone_shallows) unless clone_shallows.empty?

      if submodules
        store = Object::Store.new(repo)
        clone_sub = ->(sub_url : String, sub_dir : String) {
          Client.clone(sub_url, Git.fs(sub_dir), on_progress: on_progress, lfs: lfs, submodules: true, credentials: credentials)
          nil
        }
        Repository::Submodule.init_all(into.root, repo.git_dir.root, remote, store, lfs, on_progress, credentials, clone_sub)
      end
    end

    private def self.pull_with_transport(
      remote : Transport::RemoteURL,
      store : Object::Store,
      local_tip : Object::Id,
      branch : String,
      pack_path : String,
      on_progress : Protocol::ProgressCallback?,
      shallows : Array(Object::Id),
      credentials : Transport::Credentials? = nil,
    ) : {Array(Repository::Ref), Pack::Resolver, Array(Object::Id), Array(Object::Id)}
      transport = Transport.for(remote, credentials)
      run_pull_session(Protocol::Negotiator.open(transport), branch, local_tip, pack_path, on_progress, shallows, store)
    end

    private def self.run_clone_fetch(
      session : Protocol::Session,
      pack_path : String,
      depth : Int32?,
      branch : String,
      on_progress : Protocol::ProgressCallback?,
    ) : {Array(Repository::Ref), Repository::Ref, Array(Object::Id), Int32}
      refs = session.refs
      raise Error.new("Remote repository has no refs") if refs.empty?
      target = resolve_target(refs, branch)

      clone_shallows = [] of Object::Id
      object_count = 0
      session.fetch([target.oid], depth: depth, on_progress: on_progress) do |pack_io, shallows, _|
        clone_shallows = shallows
        object_count = Pack::File.receive(pack_io, pack_path)
      end
      session.close

      {refs, target, clone_shallows, object_count}
    end

    private def self.resolve_and_index(
      pack_path : String,
      count : Int32,
      store : Object::BlobSource? = nil,
      make_resolver : Proc(String, Int32, Pack::Resolver) = ->(p : String, c : Int32) { Pack::Resolver.new(p, c) },
    ) : Pack::Resolver
      resolver = make_resolver.call(pack_path, count)
      resolver.resolve!(store)
      Pack::IndexWriter.write_for_pack(resolver.sha1_map.values, pack_path)
      resolver
    end

    private def self.index_and_checkout(
      repo : Repository,
      target : Repository::Ref,
      work_dir : FileSystem,
      object_count : Int32,
      lfs_client : LFS::Client?,
    ) : Object::Id
      resolver = resolve_and_index(repo.packfile_path, object_count)
      commit_oid = peel_to_commit(target.oid, resolver)
      Worktree::Checkout.run(resolver, commit_oid, work_dir, lfs_client)
      commit_oid
    end

    # Selects the target ref for the clone. "HEAD" resolves to the remote's default branch.
    private def self.resolve_target(refs : Array(Repository::Ref), branch : String) : Repository::Ref
      branch == "HEAD" ? resolve_head_target(refs) : resolve_named_target(refs, branch)
    end

    private def self.resolve_head_target(refs : Array(Repository::Ref)) : Repository::Ref
      head = refs.find(&.head?)
      unless head
        return refs.find(&.branch?) ||
          refs.first? ||
          raise Error.new("No refs found on remote")
      end
      # Prefer the symref target (from v2 symref-target or v1 symref capability)
      # so we get the correct branch even when two branches point at the same commit.
      if symref = head.symref_target
        refs.find { |ref| ref.name == symref } || head
      else
        refs.find { |ref| ref.branch? && ref.oid == head.oid } || head
      end
    end

    private def self.resolve_named_target(refs : Array(Repository::Ref), branch : String) : Repository::Ref
      refs.find { |ref| ref.name == "refs/heads/#{branch}" } ||
        refs.find { |ref| ref.name == "refs/tags/#{branch}" } ||
        raise Error.new("Branch or tag #{branch.inspect} not found on remote")
    end

    # Follows a tag object chain until a non-tag type is reached; returns the commit OID.
    private def self.peel_to_commit(oid : Object::Id, resolver : Pack::Resolver) : Object::Id
      current = oid
      loop do
        result = resolver[current] || raise Error.new("Object #{current.to_hex} not found in pack")
        type, data = result
        break unless type.tag?
        current = Object::Tag.parse(data).object
      end
      current
    end

    private def self.finalize_repo(
      repo : Repository,
      refs : Array(Repository::Ref),
      target : Repository::Ref,
      url : String,
      commit_oid : Object::Id,
    ) : Nil
      repo.write_packed_refs(refs)
      if branch = target.branch_name
        repo.write_head(branch)
      else
        repo.write_detached_head(commit_oid)
      end
      repo.write_config(url)
      repo.write_tracking_refs("origin", refs)
      branch_name = target.branch_name || "HEAD"
      repo.write_fetch_head(target.oid, branch_name, url)

      zero_oid = Git.oid("0" * 40)
      clone_msg = "clone: from #{url}"
      repo.append_reflog("HEAD", zero_oid, commit_oid, clone_msg)
      if branch = target.branch_name
        repo.append_reflog("refs/heads/#{branch}", zero_oid, commit_oid, clone_msg)
      end
      refs.each do |ref|
        if b = ref.branch_name
          repo.append_reflog("refs/remotes/origin/#{b}", zero_oid, ref.oid, clone_msg)
        end
      end
    end

    private def self.run_pull_session(
      session : Protocol::Session,
      branch : String,
      local_tip : Object::Id,
      pack_path : String,
      on_progress : Protocol::ProgressCallback?,
      shallows : Array(Object::Id),
      store : Object::Store,
    ) : {Array(Repository::Ref), Pack::Resolver, Array(Object::Id), Array(Object::Id)}
      refs = session.refs
      raise Error.new("Remote repository has no refs") if refs.empty?
      target = refs.find { |ref| ref.branch? && ref.branch_name == branch } ||
               raise Error.new("Branch #{branch.inspect} not found on remote")

      new_shallows = [] of Object::Id
      unshallowed = [] of Object::Id
      object_count = 0
      session.fetch([target.oid], [local_tip], shallows: shallows, on_progress: on_progress) do |pack_io, fetched_shallows, fetched_unshallowed|
        new_shallows = fetched_shallows
        unshallowed = fetched_unshallowed
        object_count = Pack::File.receive(pack_io, pack_path)
      end
      session.close

      {refs, resolve_and_index(pack_path, object_count, store), new_shallows, unshallowed}
    end
  end
end
