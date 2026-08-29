require_relative "./changelog_source"
require_relative "./playbook_kit_usage"
require_relative "./public_dependency_retriever"

module TestPlan
  module DependencyDelta
    class Generator
      FULL_LIMIT = 10 * 1024 * 1024
      CONTEXT_TOTAL_LIMIT = 500 * 1024
      # Floor on a dependency's share. Below this a slice is too small to say anything
      # useful, so it is better to spend the budget on the dependencies sorted first --
      # direct, then Git-pinned -- and let the tail fall off.
      CONTEXT_MINIMUM_PER_DEPENDENCY = 25 * 1024

      def initialize(changes:, retriever: PublicRetriever.new, changelog: ChangelogSource.new,
                     kit_usage: PlaybookKitUsage.disabled, problems: [])
        @changes = changes.sort_by { |change| [change.direct ? 0 : 1, change.source == "git" ? 0 : 1, change.name] }
        @retriever = retriever
        @changelog = changelog
        @kit_usage = kit_usage
        @problems = problems
        @related = build_related(@changes)
      end

      def generate
        full = +""
        context = +""
        entries = []
        remaining_context = CONTEXT_TOTAL_LIMIT
        remaining_changes = @changes.length

        @changes.each do |change|
          entry = change.to_h
          entry["related"] = related_for(change)
          entry["warnings"] = []
          entry["degraded"] = false
          begin
            diffs = retrieve_diffs(change, entry)
            @kit_usage.observe(change, diffs)
            entry["changed_files"] = diffs.length
            header = dependency_header(change)

            # The artifact and the provider context have separate budgets. Only the
            # context affects the generated plan, so only it decides the status; the
            # shared artifact budget being spent by earlier dependencies says nothing
            # about this one's evidence.
            omitted_from_artifact = append_chunks(full, header, diffs, FULL_LIMIT, :artifact_text)

            candidates = context_candidates(entry.fetch("related"), diffs)
            excluded = diffs - candidates
            omitted_from_context = []

            if candidates.any?
              budget = context_budget(remaining_context, remaining_changes)
              dependency_context = +""
              omitted_from_context =
                append_chunks(dependency_context, header, candidates, budget, :context_text)
              context << dependency_context
              remaining_context -= dependency_context.bytesize

              if omitted_from_context.any?
                entry["warnings"] << "Provider context budget of #{kib(budget)} was exhausted; " \
                  "#{omitted_from_context.length} file diffs were omitted."
              end
            end

            if excluded.any?
              entry["warnings"] << "Kept #{excluded.length} generated build files out of the provider " \
                "context; #{entry.fetch("related").join(", ")} carries the source for the same " \
                "release. They remain in the full-delta artifact."
            end

            entry["status"] = omitted_from_context.any? ? "truncated" : "retrieved"

            if omitted_from_artifact.any?
              entry["warnings"] << "The full-delta artifact reached its #{mib(FULL_LIMIT)} limit; " \
                "#{omitted_from_artifact.length} file diffs are missing from the artifact only, not " \
                "from the provider context."
            end

            entry["context_files"] = candidates.length - omitted_from_context.length
            entry["omitted_from_context"] = omitted_from_context.sort
            entry["excluded_generated"] = excluded.map(&:path).sort
            entry["omitted_from_artifact"] = omitted_from_artifact.sort
          rescue => e
            entry["status"] = "unavailable"
            entry["degraded"] = true
            entry["warnings"] = [e.message]
            entry["changed_files"] = 0
            entry["context_files"] = 0
            entry["omitted_from_context"] = []
            entry["excluded_generated"] = []
            entry["omitted_from_artifact"] = []
          end
          remaining_changes -= 1
          entries << entry
        end

        lockfile_warnings = @problems.map(&:to_h)

        {
          manifest: {
            "version" => 1,
            "dependencies" => entries,
            "lockfile_warnings" => lockfile_warnings,
            # Counts anything that cost evidence, which is not the same as anything
            # that produced a warning: build output kept out of a linked release, and
            # an artifact that ran out of room while the provider context did not, are
            # both expected and neither degrades the plan.
            "warning_count" => entries.count { |entry| incomplete?(entry) } +
              lockfile_warnings.length,
          },
          full: full,
          context: context,
          kit_usage: @kit_usage.report,
        }
      end

    private

      # The changelog comes from the repository rather than the package, so it can
      # survive a package download the registry refuses -- which is the difference
      # between no evidence at all and the release notes for the version being tested.
      def retrieve_diffs(change, entry)
        changelog = @changelog.diffs_for(change)

        begin
          changelog + @retriever.retrieve(change)
        rescue => e
          raise if changelog.empty?

          entry["warnings"] << "#{e.message}. The changelog was still read from the repository."
          entry["degraded"] = true
          changelog
        end
      end

      def incomplete?(entry)
        entry.fetch("status") != "retrieved" || entry.fetch("degraded", false)
      end

      # Share what is left among the dependencies still to come, so a lone dependency --
      # a Playbook bump, typically -- can use the whole budget instead of a fixed slice of
      # it, and an early dependency that came in small hands its surplus to the next.
      def context_budget(remaining_context, remaining_changes)
        share = remaining_context / [remaining_changes, 1].max
        [[share, CONTEXT_MINIMUM_PER_DEPENDENCY].max, remaining_context].min
      end

      # One upstream release published as a gem and a package: the build output in this
      # half is compiled from source that reaches the provider through the other half, so
      # spending context on minified bundles would only crowd that source out. Everything
      # that is not build output still goes through -- an npm tarball's package.json says
      # something its gem counterpart does not.
      #
      # Assumes the linked sibling carries source. That holds for a gem-and-package pair,
      # where the gem ships source by construction; two all-generated halves would leave
      # the release with no context, which the warnings would make visible.
      def context_candidates(related, diffs)
        return diffs if related.empty?

        diffs.reject(&:generated?)
      end

      def kib(bytes)
        "#{bytes / 1024} KiB"
      end

      def mib(bytes)
        "#{bytes / 1024 / 1024} MiB"
      end

      # A gem and an npm package released in lockstep from one upstream project -- Playbook
      # is the case this exists for -- are one release, not two independent upgrades. Their
      # published artifacts genuinely differ (Rails kits versus compiled components), so
      # both deltas are kept; the link only stops the provider reading them as two
      # unrelated changes and writing coverage twice.
      def build_related(changes)
        changes
          .group_by { |change| [release_name(change), change.old_version, change.new_version] }
          .each_with_object({}) do |(_release, group), related|
            next if group.map(&:ecosystem).uniq.length < 2

            group.each do |change|
              related[change.key] = (group - [change])
                .map { |other| "#{other.ecosystem}:#{other.name}" }
                .sort
            end
          end
      end

      def release_name(change)
        change.name.to_s.sub(%r{\A@[^/]+/}, "").downcase.tr("_", "-")
      end

      def related_for(change)
        @related.fetch(change.key, [])
      end

      def dependency_header(change)
        related = related_for(change)
        heading = "\n## #{change.ecosystem}: #{change.name} (#{change.old_version} -> #{change.new_version})\n"
        return "#{heading}\n" if related.empty?

        "#{heading}Same upstream release as #{related.join(", ")}.\n\n"
      end

      SEPARATOR = "\n".freeze

      # Returns the paths that did not fit, so every omission can be named in the
      # manifest. `text` selects what a diff contributes: the artifact records the whole
      # thing, while the provider may be shown a capped form of it.
      def append_chunks(target, header, diffs, limit, text)
        return diffs.map(&:path) if target.bytesize + header.bytesize > limit

        omitted = []
        target << header
        diffs.each do |source_diff|
          body = source_diff.public_send(text)
          # The separator counts against the limit too; without it the advertised cap
          # was exceeded by a byte for every diff included.
          if target.bytesize + body.bytesize + SEPARATOR.bytesize > limit
            omitted << source_diff.path
            next
          end
          target << body << SEPARATOR
        end
        omitted
      end

    end
  end
end
