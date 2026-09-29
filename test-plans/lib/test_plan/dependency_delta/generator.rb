# frozen_string_literal: true

require_relative "../playbook/packages"
require_relative "./changelog_source"
require_relative "./playbook_kit_usage"
require_relative "./public_dependency_retriever"
require_relative "./version_spelling"

module TestPlan
  module DependencyDelta
    class Generator
      FULL_LIMIT = 10 * 1024 * 1024
      CONTEXT_TOTAL_LIMIT = 1024 * 1024
      # Floor on a dependency's share. Spent ahead of the fair share, so a run with more
      # than CONTEXT_TOTAL_LIMIT / this many dependencies leaves its tail with nothing --
      # hence the blast-radius sort.
      CONTEXT_MINIMUM_PER_DEPENDENCY = 25 * 1024

      # Playbook's kit changes reach many call sites, where an ordinary gem bump is read
      # alongside the code calling it.
      WEIGHTED_PACKAGES = Playbook::PACKAGE_NAMES
      WEIGHTED_CONTEXT_SHARE = 4
      DEFAULT_CONTEXT_SHARE = 1

      def initialize(changes:, retriever: PublicRetriever.new, changelog: ChangelogSource.new,
                     kit_usage: PlaybookKitUsage.disabled, problems: [], out_of_scope: [])
        # Blast radius before name: nearly everything is direct and from a registry, which
        # left the alphabet deciding who got funded first.
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
        @out_of_scope = out_of_scope
        @related = build_related(@changes)
      end

      def generate
        full = +""
        context = +""
        entries = []
        remaining_context = CONTEXT_TOTAL_LIMIT
        remaining_weight = @changes.sum { |change| context_weight(change) }

        @changes.each do |change|
          entry, context_bytes = build_entry(change, full, context, remaining_context, remaining_weight)
          remaining_context -= context_bytes
          remaining_weight -= context_weight(change)
          entries << entry
        end

        lockfile_warnings = @problems.map(&:to_h)

        {
          manifest: {
            "version" => 1,
            "dependencies" => entries,
            "lockfile_warnings" => lockfile_warnings,
            # Recorded, so a reader can find a raise they know landed.
            "out_of_scope" => @out_of_scope.map { |change| out_of_scope_entry(change) },
            # Only what cost evidence, which is not everything that warned: build output
            # kept out of a linked release, and a full artifact with room left in the
            # context, are both expected.
            "warning_count" => entries.count { |entry| incomplete?(entry) } +
              lockfile_warnings.length,
          },
          full:,
          context:,
          kit_usage: @kit_usage.report,
        }
      end

      private

      def build_entry(change, full, context, remaining_context, remaining_weight)
        starting_context_bytes = context.bytesize
        entry = change.to_h
        entry["related"] = related_for(change)
        entry["warnings"] = []
        entry["degraded"] = false

        diffs = retrieve_diffs(change, entry)
        @kit_usage.observe(change, diffs)
        entry["changed_files"] = diffs.length
        header = dependency_header(change)

        # Only the context affects the generated plan, so only it decides the status;
        # the shared artifact budget says nothing about this dependency's evidence.
        omitted_artifact = append_chunks(full, header, diffs, FULL_LIMIT, :artifact_text)
        candidates = context_candidates(entry.fetch("related"), diffs)
        excluded = diffs - candidates
        omitted_context, context_bytes = append_provider_context(
          entry, change, header, candidates, context, remaining_context, remaining_weight
        )
        record_omissions(entry, candidates, excluded, omitted_context, omitted_artifact)
        [entry, context_bytes]
      rescue => e
        entry["status"] = "unavailable"
        entry["degraded"] = true
        entry["warnings"] = [e.message]
        entry["changed_files"] = 0
        entry["context_files"] = 0
        entry["omitted_from_context"] = []
        entry["excluded_generated"] = []
        entry["omitted_from_artifact"] = []
        [entry, context.bytesize - starting_context_bytes]
      end

      def append_provider_context(entry, change, header, candidates, context, remaining_context, remaining_weight)
        return [[], 0] if candidates.empty?

        budget = context_budget(remaining_context, remaining_weight, context_weight(change))
        dependency_context = +""
        omitted = append_chunks(dependency_context, header, candidates, budget, :context_text)
        context << dependency_context
        entry["warnings"] << budget_warning(budget, omitted) if omitted.any?
        [omitted, dependency_context.bytesize]
      end

      def record_omissions(entry, candidates, excluded, omitted_context, omitted_artifact)
        if excluded.any?
          entry["warnings"] << "Kept #{excluded.length} generated build files out of the provider " \
            "context; #{entry.fetch("related").join(", ")} carries the source for the same " \
            "release. They remain in the full-delta artifact."
        end

        # Only lost evidence truncates; dropping tests and docs off the tail is the
        # priority order working. Every omission is named either way.
        entry["status"] = omitted_context.any?(&:evidence?) ? "truncated" : "retrieved"

        if omitted_artifact.any?
          entry["warnings"] << "The full-delta artifact reached its #{mib(FULL_LIMIT)} limit; " \
            "#{omitted_artifact.length} file diffs are missing from the artifact only, not " \
            "from the provider context."
        end

        entry["context_files"] = candidates.length - omitted_context.length
        entry["omitted_from_context"] = omitted_context.map(&:path).sort
        entry["excluded_generated"] = excluded.map(&:path).sort
        entry["omitted_from_artifact"] = omitted_artifact.map(&:path).sort
      end

      # The changelog comes from the repository, so it survives a package download the
      # registry refuses.
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

      def out_of_scope_entry(change)
        {
          "ecosystem" => change.ecosystem,
          "name" => change.name,
          "old_version" => change.old_version,
          "new_version" => change.new_version,
          "lockfiles" => change.lockfiles.sort,
        }
      end

      def incomplete?(entry)
        entry.fetch("status") != "retrieved" || entry.fetch("degraded", false)
      end

      # Weighted share of what is left, so a dependency that came in small hands its
      # surplus on. remaining_weight still counts this one, so the last gets the rest.
      def context_budget(remaining_context, remaining_weight, weight)
        share = remaining_context * weight / [remaining_weight, 1].max
        [[share, CONTEXT_MINIMUM_PER_DEPENDENCY].max, remaining_context].min
      end

      def context_weight(change)
        WEIGHTED_PACKAGES.include?(change.name) ? WEIGHTED_CONTEXT_SHARE : DEFAULT_CONTEXT_SHARE
      end

      # This half's build output is compiled from source reaching the provider through the
      # other half, so spending context on minified bundles crowds that source out.
      # Non-generated files still go through: an npm package.json says what a gem's does
      # not. Assumes the sibling carries source, which holds for a gem-and-package pair.
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

      # A gem and a package released in lockstep are one release. Both deltas are kept --
      # the artifacts genuinely differ -- and the link only stops the provider covering
      # the same change twice.
      #
      # A list of groups, so another linked pair can be added beside Playbook's. Named
      # rather than inferred: matching on normalised names and equal versions would link
      # an unrelated widget_ui gem and widget-ui package that happened to bump together,
      # and linking drops each half's build output, so a wrong link silently costs both
      # of them their evidence.
      LINKED_RELEASES = [
        Playbook::PACKAGE_NAMES,
      ].freeze

      # Canonical versions, not the lockfile's strings: the two halves spell a prerelease
      # differently, so raw comparison failed to link exactly the RC bumps this is for.
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

      # Returns the diff objects that did not fit; `text` picks the artifact's copy or the
      # provider's capped one.
      def append_chunks(target, header, diffs, limit, text)
        return diffs if target.bytesize + header.bytesize > limit

        omitted = []
        target << header
        diffs.each do |source_diff|
          body = source_diff.public_send(text)
          # The separator counts against the limit; without it the cap was exceeded by a
          # byte per diff.
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
