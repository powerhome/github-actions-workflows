require "json"

require_relative "../untrusted_text"
require_relative "./change_detector"
require_relative "./generator"
require_relative "./playbook_kit_usage"
require_relative "./git_snapshot"

module TestPlan
  module DependencyDelta
    class Command
      WARNING_MESSAGE = "Some external dependency evidence could not be collected completely; see the workflow run and dependency manifest."

      def run
        workspace = ENV.fetch("GITHUB_WORKSPACE")
        snapshot = GitSnapshot.new(
          workspace: workspace,
          base_sha: ENV.fetch("BASE_SHA"),
          head_sha: ENV.fetch("HEAD_SHA")
        )
        detector = ChangeDetector.new(snapshot)
        changes = detector.detect
        result = Generator.new(
          changes: changes,
          kit_usage: PlaybookKitUsage.new(workspace: workspace),
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
        write_outputs(changes.length, warning_count)
        write_summary(result.fetch(:manifest))
        log_manifest(manifest_path, result.fetch(:manifest))
        puts("::warning::#{WARNING_MESSAGE}") if warning_count.positive?
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
        puts(JSON.pretty_generate(manifest))
        puts("::endgroup::")
      end

      def write_outputs(change_count, warning_count)
        File.open(ENV.fetch("GITHUB_OUTPUT"), "a", encoding: Encoding::UTF_8) do |output|
          output.puts("change_count=#{change_count}")
          output.puts("warning_count=#{warning_count}")
          output.puts("generation_warning=#{warning_count.positive? ? WARNING_MESSAGE : ""}")
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
