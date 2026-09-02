require "json"

require_relative "../untrusted_text"
require_relative "./change_detector"
require_relative "./generator"
require_relative "./playbook_kit_usage"
require_relative "./git_snapshot"

module TestPlan
  module DependencyDelta
    class Command
      # The comment names which dependencies and why; the manifest keeps the file lists.
      WARNING_HEADLINE = "Some external dependency evidence is incomplete"
      MANIFEST_POINTER = "The dependency manifest in the workflow run names every omitted file."
      # Past this the sentence stops being readable, and the manifest has the rest.
      MAX_NAMED_DEPENDENCIES = 4
      UNAVAILABLE_REASON = "could not be retrieved"
      DEGRADED_REASON = "source refused, changelog only"
      TRUNCATED_REASON = "provider context budget exhausted"

      def run
        workspace = ENV.fetch("GITHUB_WORKSPACE")
        snapshot = GitSnapshot.new(
          workspace: workspace,
          base_sha: ENV.fetch("BASE_SHA"),
          head_sha: ENV.fetch("HEAD_SHA")
        )
        detector = ChangeDetector.new(snapshot, scope: ENV.fetch("DEPENDENCY_SCOPE", "umbrella"))
        changes = detector.detect
        kit_usage = PlaybookKitUsage.new(workspace: workspace)
        result = Generator.new(
          changes: changes,
          kit_usage: kit_usage,
          problems: detector.problems,
          out_of_scope: detector.out_of_scope
        ).generate

        manifest_path = ENV.fetch("DEPENDENCY_DELTA_MANIFEST_PATH")
        full_path = ENV.fetch("DEPENDENCY_DELTA_FULL_PATH")
        context_path = ENV.fetch("DEPENDENCY_DELTA_CONTEXT_PATH")
        File.write(manifest_path, JSON.pretty_generate(result.fetch(:manifest)) + "\n", encoding: Encoding::UTF_8)
        File.write(full_path, result.fetch(:full), encoding: Encoding::UTF_8)
        File.write(context_path, result.fetch(:context), encoding: Encoding::UTF_8)

        kit_usage_path = ENV.fetch("DEPENDENCY_KIT_USAGE_PATH")
        # A separate name: kit_usage is the usage object the later writes still need.
        report = result.fetch(:kit_usage).to_s
        report += other_raises_section(changes) unless report.empty?
        File.write(kit_usage_path, report, encoding: Encoding::UTF_8)

        # Written whatever the raise was, so the render step has a file to read and the
        # artifact upload has nothing to warn about. The provider is never pointed at it:
        # it exists for the renderer, and a document meant for one reader is a document the
        # other will reason from.
        File.write(
          ENV.fetch("PLAYBOOK_KIT_FACTS_PATH"),
          JSON.pretty_generate(kit_usage.facts) + "\n",
          encoding: Encoding::UTF_8
        )

        warning_count = result.dig(:manifest, "warning_count")
        warning = warning_count.positive? ? warning_message(result.fetch(:manifest)) : ""
        write_outputs(
          changes.length, warning_count, warning, kit_usage.kits, snapshot.declarations_only?
        )
        write_summary(result.fetch(:manifest), kit_usage.facts)
        log_manifest(manifest_path, result.fetch(:manifest))
        puts("::warning::#{warning}") unless warning.empty?
      end

    private

      # The runner is ephemeral, so otherwise the reason for a warning is only in the
      # artifact. Unescaped is safe: a workflow command has to start its own line, and
      # JSON.pretty_generate escapes newlines inside strings.
      def log_manifest(path, manifest)
        puts("::group::Dependency delta manifest (#{path})")
        puts(JSON.pretty_generate(loggable(manifest)))
        puts("::endgroup::")
      end

      # playbook_ui is in ~140 component Gemfile.locks; printed in full they bury the
      # warnings. The file and the artifact keep all of them.
      LOGGED_LOCKFILES = 5

      def loggable(manifest)
        dependencies = manifest.fetch("dependencies").map do |entry|
          lockfiles = entry.fetch("lockfiles", [])
          next entry if lockfiles.length <= LOGGED_LOCKFILES

          entry.merge(
            "lockfiles" => lockfiles.first(LOGGED_LOCKFILES) +
              ["...and #{lockfiles.length - LOGGED_LOCKFILES} more (see the manifest artifact)"]
          )
        end

        manifest.merge("dependencies" => dependencies)
      end

      # Names are escaped here, not by the formatter: they come from lockfiles the pull
      # request can edit, and the formatter renders this as the Markdown it was handed.
      # One line too -- the value goes to GITHUB_OUTPUT, where a newline would end it.
      def warning_message(manifest)
        grouped = manifest.fetch("dependencies").each_with_object({}) do |entry, groups|
          reason = reason_for(entry)
          next unless reason

          (groups[reason] ||= []) << escape(entry["name"])
        end

        parts = grouped.map { |reason, names| "#{name_list(names)} (#{reason})" }

        lockfiles = manifest.fetch("lockfile_warnings").length
        parts << "#{lockfiles} lockfile#{"s" if lockfiles > 1} could not be analyzed" if lockfiles.positive?
        return "" if parts.empty?

        single_line("#{WARNING_HEADLINE}: #{parts.join("; ")}. #{MANIFEST_POINTER}")
      end

      def reason_for(entry)
        return UNAVAILABLE_REASON if entry.fetch("status") == "unavailable"
        return DEGRADED_REASON if entry.fetch("degraded", false)
        return TRUNCATED_REASON if entry.fetch("status") != "retrieved"

        nil
      end

      def name_list(names)
        return names.join(", ") if names.length <= MAX_NAMED_DEPENDENCIES

        "#{names.first(MAX_NAMED_DEPENDENCIES).join(", ")} and #{names.length - MAX_NAMED_DEPENDENCIES} more"
      end

      def single_line(text)
        text.gsub(/\s+/, " ").strip
      end

      def write_outputs(change_count, warning_count, warning, kits, declarations_only)
        File.open(ENV.fetch("GITHUB_OUTPUT"), "a", encoding: Encoding::UTF_8) do |output|
          output.puts("change_count=#{change_count}")
          output.puts("warning_count=#{warning_count}")
          output.puts("generation_warning=#{warning}")
          # First point in the run that can know: the profile resolved from the label
          # before any lockfile was read.
          output.puts("playbook_kits_changed=#{kits.any?}")
          output.puts("lockfile_only=#{declarations_only}")
        end
      end

      # Names, versions, paths and warning text all originate in lockfiles the pull
      # request can edit, or in messages built from them, and the summary is rendered as
      # Markdown. Same policy as the comment.
      def escape(value)
        UntrustedText.escape(value.to_s)
      end

      OTHER_RAISES_HEADING = "# Other dependency raises in this pull request"

      # Listed for the provider here rather than left to the manifest. The manifest also
      # records the raises this run deliberately skipped, and a provider pointed at it
      # wrote up twenty component gems nothing deploys.
      def other_raises_section(changes)
        others = changes
          .reject { |change| PlaybookKitUsage::PACKAGE_NAMES.include?(change.name) }
          .sort_by(&:name)
        return "\n#{OTHER_RAISES_HEADING}\n\nNone.\n" if others.empty?

        lines = others.map { |c| "- #{c.name} #{c.old_version} -> #{c.new_version}" }
        "\n#{OTHER_RAISES_HEADING}\n\nTheir source deltas, where one was retrieved, are in the " \
          "context diff.\n\n#{lines.join("\n")}\n"
      end

      # Kit counts are passed in rather than read from the manifest: the manifest is a
      # document the provider can open, and a count it can see is a count it can copy back
      # as its own. The summary is read by people.
      def write_summary(manifest, kit_facts = { "kits" => {} })
        summary_path = ENV["GITHUB_STEP_SUMMARY"]
        return if summary_path.to_s.empty?

        dependencies = manifest.fetch("dependencies")
        lockfile_warnings = manifest.fetch("lockfile_warnings")
        File.open(summary_path, "a", encoding: Encoding::UTF_8) do |summary|
          summary.puts("## External dependency delta")
          if dependencies.empty?
            summary.puts("No raised external Bundler or Yarn dependencies were detected.")
          else
            dependencies.each do |entry|
              summary.puts(
                "- #{escape(entry.fetch("name"))}: #{escape(entry.fetch("old_version"))} -> " \
                  "#{escape(entry.fetch("new_version"))} (#{entry.fetch("status")})"
              )
              entry.fetch("warnings").each { |warning| summary.puts("  - #{escape(warning)}") }
              omitted = entry.fetch("omitted_from_context", [])
              omitted.first(10).each { |path| summary.puts("  - omitted from context: #{escape(path)}") }
              summary.puts("  - ...and #{omitted.length - 10} more") if omitted.length > 10
            end
          end

          kits = kit_facts.fetch("kits", {})
          unless kits.empty?
            summary.puts("- Playbook kits changed: #{kits.length}")
            kits.each_value do |kit|
              sites = kit.fetch("call_sites")
              summary.puts(
                "  - #{escape(kit.fetch("name"))}: #{sites} call #{sites == 1 ? "site" : "sites"} " \
                  "(#{escape(kit.fetch("coverage"))})"
              )
            end
          end

          lockfile_warnings.each do |warning|
            summary.puts("- #{escape(warning.fetch("lockfile"))}: not analyzed")
            summary.puts("  - #{escape(warning.fetch("warning"))}")
          end

          out_of_scope = manifest.fetch("out_of_scope", [])
          next if out_of_scope.empty?

          summary.puts(
            "- #{out_of_scope.length} raised #{out_of_scope.length == 1 ? "dependency" : "dependencies"} " \
              "reached no root lockfile and were not analyzed"
          )
          out_of_scope.each do |entry|
            summary.puts(
              "  - #{escape(entry.fetch("name"))}: #{escape(entry.fetch("old_version"))} -> " \
                "#{escape(entry.fetch("new_version"))}"
            )
          end
        end
      end
    end
  end
end
