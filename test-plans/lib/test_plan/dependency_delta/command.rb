require "json"

require_relative "../untrusted_text"
require_relative "./change_detector"
require_relative "./generator"
require_relative "./playbook_kit_usage"
require_relative "./git_snapshot"

module TestPlan
  module DependencyDelta
    class Command
      # Named, not generic. "Some external dependency evidence could not be collected
      # completely" told a reader that something was wrong but not what or where, so the
      # next question was always the manifest. The comment says which dependencies and
      # why; the manifest is still where the file lists live.
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
        detector = ChangeDetector.new(snapshot)
        changes = detector.detect
        kit_usage = PlaybookKitUsage.new(workspace: workspace)
        result = Generator.new(
          changes: changes,
          kit_usage: kit_usage,
          problems: detector.problems
        ).generate

        manifest_path = ENV.fetch("DEPENDENCY_DELTA_MANIFEST_PATH")
        full_path = ENV.fetch("DEPENDENCY_DELTA_FULL_PATH")
        context_path = ENV.fetch("DEPENDENCY_DELTA_CONTEXT_PATH")
        File.write(manifest_path, JSON.pretty_generate(result.fetch(:manifest)) + "\n", encoding: Encoding::UTF_8)
        File.write(full_path, result.fetch(:full), encoding: Encoding::UTF_8)
        File.write(context_path, result.fetch(:context), encoding: Encoding::UTF_8)

        kit_usage_path = ENV.fetch("DEPENDENCY_KIT_USAGE_PATH")
        File.write(kit_usage_path, result.fetch(:kit_usage).to_s, encoding: Encoding::UTF_8)

        warning_count = result.dig(:manifest, "warning_count")
        warning = warning_count.positive? ? warning_message(result.fetch(:manifest)) : ""
        write_outputs(changes.length, warning_count, warning, kit_usage.kits)
        write_summary(result.fetch(:manifest))
        log_manifest(manifest_path, result.fetch(:manifest))
        puts("::warning::#{warning}") unless warning.empty?
      end

    private

      # The runner is ephemeral, so without this the reason for a warning is only in the
      # artifact, behind a download and an unzip.
      #
      # Unescaped is safe here: a workflow command has to start its own line, and
      # JSON.pretty_generate escapes newlines inside strings, so no lockfile-derived
      # value can open one.
      def log_manifest(path, manifest)
        puts("::group::Dependency delta manifest (#{path})")
        puts(JSON.pretty_generate(loggable(manifest)))
        puts("::endgroup::")
      end

      # playbook_ui is a dependency of every component, which is about 140 Gemfile.locks
      # in nitro-web -- printed in full they bury the warnings this group exists to show.
      # The file and the artifact keep the whole list; only the log is trimmed.
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

      # Groups the incomplete dependencies by why they are incomplete, so one reason is
      # stated once however many dependencies share it.
      #
      # Names are escaped here rather than by the formatter: they come from lockfiles the
      # pull request can edit, and the formatter renders this warning as the Markdown it
      # was handed. Same policy as the job summary below. Collapsed to one line as well,
      # because the value is written to GITHUB_OUTPUT, where a newline would end the
      # value and let a lockfile append outputs of its own.
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

      def write_outputs(change_count, warning_count, warning, kits)
        File.open(ENV.fetch("GITHUB_OUTPUT"), "a", encoding: Encoding::UTF_8) do |output|
          output.puts("change_count=#{change_count}")
          output.puts("warning_count=#{warning_count}")
          output.puts("generation_warning=#{warning}")
          # The plan is shaped differently for a Playbook raise, and this step is the
          # first point in the run that knows there was one: the profile resolved from the
          # label before any lockfile had been read.
          output.puts("playbook_kits_changed=#{kits.any?}")
        end
      end

      # Names, versions, paths and warning text all originate in lockfiles the pull
      # request can edit, or in messages built from them, and the summary is rendered as
      # Markdown. Same policy as the comment.
      def escape(value)
        UntrustedText.escape(value.to_s)
      end

      def write_summary(manifest)
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

          lockfile_warnings.each do |warning|
            summary.puts("- #{escape(warning.fetch("lockfile"))}: not analyzed")
            summary.puts("  - #{escape(warning.fetch("warning"))}")
          end
        end
      end
    end
  end
end
