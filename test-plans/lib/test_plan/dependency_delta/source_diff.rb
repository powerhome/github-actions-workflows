require_relative "./source_diff_builder"

module TestPlan
  module DependencyDelta
    SourceDiff = Struct.new(:path, :diff, :priority, :context_diff, keyword_init: true) do
      # What the artifact records, and what the provider is shown, can differ: an
      # oversized changelog is capped for the provider while the artifact keeps all of
      # it, so the omitted part stays recoverable.
      def artifact_text
        diff
      end

      def context_text
        context_diff || diff
      end

      def bytesize
        diff.bytesize
      end

      def generated?
        priority == SourceDiffBuilder::PRIORITY_GENERATED
      end
    end
  end
end
