require_relative "./changelog_source"
require_relative "./playbook_kit_usage"
require_relative "./public_dependency_retriever"
require_relative "./version_spelling"

module TestPlan
  module DependencyDelta
    class Generator
      FULL_LIMIT = 10 * 1024 * 1024
      CONTEXT_TOTAL_LIMIT = 1024 * 1024
      # Floor on a dependency's share. Below this a slice is too small to say anything
      # useful, so it is better to spend the budget on the dependencies sorted first and
      # let the tail fall off. The floor is spent ahead of the fair share, so a run with
      # more than CONTEXT_TOTAL_LIMIT / this many dependencies leaves the tail with
      # nothing -- which is why the sort puts the widest blast radius first.
      CONTEXT_MINIMUM_PER_DEPENDENCY = 25 * 1024

      # A Playbook bump is the pull request this action exists for, and the one where
      # pr.diff says least: every file in it is a lockfile, so the dependency delta is the
      # only evidence there is. An ordinary gem bump is read alongside the application
      # code that calls it. So Playbook draws a larger slice than an equal split would
      # give it.
      #
      # Named rather than inferred, for the same reason LINKED_RELEASES is: a heuristic
      # that guessed wrong would starve the dependency the plan is actually about.
      WEIGHTED_PACKAGES = %w[playbook_ui playbook-ui].freeze
      WEIGHTED_CONTEXT_SHARE = 4
      DEFAULT_CONTEXT_SHARE = 1

      def initialize(changes:, retriever: PublicRetriever.new, changelog: ChangelogSource.new,
                     kit_usage: PlaybookKitUsage.disabled, problems: [])
        # Blast radius before name. Every dependency here is usually direct and from a
        # registry, which left the alphabet deciding who got context first -- so a gem in
        # one component was funded ahead of one in a hundred of them.
        @changes = changes.sort_by do |change|
          [
            change.direct ? 0 : 1,
            change.source == "git" ? 0 : 1,
            -change.lockfiles.length,
            change.name,
          ]
        end
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
        remaining_weight = @changes.sum { |change| context_weight(change) }

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
              budget = context_budget(remaining_context, remaining_weight, context_weight(change))
              dependency_context = +""
              omitted_from_context =
                append_chunks(dependency_context, header, candidates, budget, :context_text)
              context << dependency_context
              remaining_context -= dependency_context.bytesize

              if omitted_from_context.any?
                entry["warnings"] << budget_warning(budget, omitted_from_context)
              end
            end

            if excluded.any?
              entry["warnings"] << "Kept #{excluded.length} generated build files out of the provider " \
                "context; #{entry.fetch("related").join(", ")} carries the source for the same " \
                "release. They remain in the full-delta artifact."
            end

            # Only lost evidence truncates. A budget that ran out after the changelog and
            # the source were in, dropping tests and docs off the tail, is the priority
            # order working -- the warnings still name every omission either way.
            entry["status"] = omitted_from_context.any?(&:evidence?) ? "truncated" : "retrieved"

            if omitted_from_artifact.any?
              entry["warnings"] << "The full-delta artifact reached its #{mib(FULL_LIMIT)} limit; " \
                "#{omitted_from_artifact.length} file diffs are missing from the artifact only, not " \
                "from the provider context."
            end

            entry["context_files"] = candidates.length - omitted_from_context.length
            entry["omitted_from_context"] = omitted_from_context.map(&:path).sort
            entry["excluded_generated"] = excluded.map(&:path).sort
            entry["omitted_from_artifact"] = omitted_from_artifact.map(&:path).sort
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
          remaining_weight -= context_weight(change)
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

      # Share what is left among the dependencies still to come, weighted, so a lone
      # dependency can use the whole budget instead of a fixed slice of it, and an early
      # dependency that came in small hands its surplus to the next. remaining_weight
      # still counts this dependency, so the last one is handed everything left.
      def context_budget(remaining_context, remaining_weight, weight)
        share = remaining_context * weight / [remaining_weight, 1].max
        [[share, CONTEXT_MINIMUM_PER_DEPENDENCY].max, remaining_context].min
      end

      def context_weight(change)
        WEIGHTED_PACKAGES.include?(change.name) ? WEIGHTED_CONTEXT_SHARE : DEFAULT_CONTEXT_SHARE
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

      def budget_warning(budget, omitted)
        dropped = omitted.count(&:evidence?)
        return "Provider context budget of #{kib(budget)} was exhausted; #{omitted.length} " \
          "supporting diffs (tests, documentation, build output) were omitted. Every " \
          "changelog and source diff was included." if dropped.zero?

        "Provider context budget of #{kib(budget)} was exhausted; #{omitted.length} file " \
          "diffs were omitted, #{dropped} of them changelog or source."
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
      #
      # The pairs are named rather than inferred. Matching on a normalised name and equal
      # versions would have linked an unrelated widget_ui gem and widget-ui package that
      # happened to bump together, and linking drops each half's build output from the
      # provider context -- so a wrong link silently costs both of them their evidence.
      LINKED_RELEASES = [
        %w[playbook_ui playbook-ui],
      ].freeze

      # Canonical versions, not the lockfile's own strings: the two halves spell a
      # prerelease differently, so raw comparison failed to link exactly the
      # release-candidate bumps this exists for.
      def build_related(changes)
        changes
          .group_by do |change|
            [
              linked_release(change),
              VersionSpelling.canonical(change.old_version),
              VersionSpelling.canonical(change.new_version),
            ]
          end
          .each_with_object({}) do |(key, group), related|
            # key is [linked release, old version, new version]; a nil release means the
            # package is not half of a named pair.
            next if key.first.nil?
            next if group.map(&:ecosystem).uniq.length < 2

            group.each do |change|
              related[change.key] = (group - [change])
                .map { |other| "#{other.ecosystem}:#{other.name}" }
                .sort
            end
          end
      end

      def linked_release(change)
        LINKED_RELEASES.find { |names| names.include?(change.name) }
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

      # Returns the diffs that did not fit -- the diffs rather than their paths, because
      # the caller has to ask what was lost as well as name it. `text` selects what a diff
      # contributes: the artifact records the whole thing, while the provider may be shown
      # a capped form of it.
      def append_chunks(target, header, diffs, limit, text)
        return diffs if target.bytesize + header.bytesize > limit

        omitted = []
        target << header
        diffs.each do |source_diff|
          body = source_diff.public_send(text)
          # The separator counts against the limit too; without it the advertised cap
          # was exceeded by a byte for every diff included.
          if target.bytesize + body.bytesize + SEPARATOR.bytesize > limit
            omitted << source_diff
            next
          end
          target << body << SEPARATOR
        end
        omitted
      end

    end
  end
end
