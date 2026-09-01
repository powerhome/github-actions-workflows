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

      # Whether dropping this costs the plan evidence. Tests, documentation and build
      # output support the changelog and the source rather than stand in for them, so
      # losing them to a budget is not the same as losing the change itself. An
      # unclassified diff counts as evidence: a wrong guess should not quietly downgrade
      # a warning.
      def evidence?
        (priority || SourceDiffBuilder::PRIORITY_RUNTIME) <= SourceDiffBuilder::PRIORITY_RUNTIME
      end
    end
  end
end
