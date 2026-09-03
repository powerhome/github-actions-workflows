module TestPlan
  module DependencyDelta
    # git grep answers in lexicographic order, which is the worst order to sample a
    # monorepo in: pb_body matched 1106 files and the first twenty were every one of them
    # under components/accounting/. A tester handed that sample covers one corner of the
    # application while the plan calls the kit covered.
    module CallSiteSample
      module_function

      # Reorders rather than truncates, so one ordering serves both an exhaustive list and
      # a sample taken off the front of it. The result is a permutation of the input.
      def spread(paths)
        groups = paths.group_by { |path| component(path) }.values
        rounds = groups.map(&:length).max.to_i

        rounds.times.flat_map { |index| groups.filter_map { |group| group[index] } }
      end

      # What makes two call sites worth visiting separately: a component has its own routes
      # and its own owners. Everything outside components/ groups by top-level directory,
      # which is as fine a distinction as those paths carry.
      def component(path)
        segments = path.to_s.split("/")
        return segments.first(2).join("/") if segments.first == "components" && segments.length > 1

        segments.first.to_s
      end
    end
  end
end
