module TestPlan
  module DependencyDelta
    # git grep answers lexicographically, the worst order to sample a monorepo in: pb_body
    # matched 1106 files and the first twenty were all under components/accounting/, so a
    # tester covers one corner while the plan calls the kit covered.
    module CallSiteSample
      module_function

      # A permutation, not a truncation, so one ordering serves both an exhaustive list
      # and a sample taken off the front.
      def spread(paths)
        groups = paths.group_by { |path| component(path) }.values
        rounds = groups.map(&:length).max.to_i

        rounds.times.flat_map { |index| groups.filter_map { |group| group[index] } }
      end

      # A component has its own routes and owners. Outside components/, the top-level
      # directory is as fine a distinction as those paths carry.
      def component(path)
        segments = path.to_s.split("/")
        return segments.first(2).join("/") if segments.first == "components" && segments.length > 1

        segments.first.to_s
      end
    end
  end
end
