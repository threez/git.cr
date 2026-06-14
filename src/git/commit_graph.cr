module Git
  # BFS-based ancestor reachability over the commit graph.
  module CommitGraph
    # Returns true if *ancestor* is reachable by following parent links from *tip*.
    # Searches *store* and *new_objects* (for freshly fetched packs).
    # Used to validate that a fetch result is a fast-forward before updating a branch ref.
    def self.ancestor?(
      tip : Object::Id,
      ancestor : Object::Id,
      store : Object::Store,
      new_objects : Pack::Resolver? = nil,
      graph : CommitGraph::Chain? = nil,
    ) : Bool
      return true if tip == ancestor

      visited = Set(Object::Id).new
      queue = Deque(Object::Id).new
      queue << tip

      while oid = queue.shift?
        next if visited.includes?(oid)
        visited << oid
        return true if oid == ancestor

        parents = graph.try(&.parents_of(oid))
        if parents
          parents.each { |parent| queue << parent unless visited.includes?(parent) }
        else
          result = store.fetch(oid, new_objects)
          next unless result
          Object::Commit.parse(result[1]).parents.each do |parent|
            queue << parent unless visited.includes?(parent)
          end
        end
      end

      false
    end
  end
end
