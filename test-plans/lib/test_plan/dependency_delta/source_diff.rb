require_relative "./source_diff_builder"

module TestPlan
  module DependencyDelta
    SourceDiff = Struct.new(:path, :diff, :priority, keyword_init: true) do
      def bytesize
        diff.bytesize
      end

      def generated?
        priority == SourceDiffBuilder::PRIORITY_GENERATED
      end
    end
  end
end
