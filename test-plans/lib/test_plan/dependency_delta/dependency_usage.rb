require "open3"

require_relative "../command_output"
require_relative "../output/untrusted_text"
require_relative "./call_site_sample"

module TestPlan
  module DependencyDelta
    # Leads, not routes: the provider still has to read the file and trace it.
    class DependencyUsage
      SEARCHED_EXTENSIONS = %w[*.rb *.erb *.haml *.js *.jsx *.ts *.tsx].freeze
      MAX_FILES_PER_PACKAGE = 8
      # Nothing a tester opens. Build output included: a committed bundle inlines its
      # dependencies, matching every package name searched for.
      NON_APPLICATION_SEGMENTS = %w[
        spec test tests __tests__ vendor node_modules docs documentation dist build
      ].freeze

      def initialize(workspace:)
        @workspace = workspace
      end

      def report(changes)
        lines = [
          "# Dependency usage candidates",
          "",
          "These are textual package-name matches in application source, not verified routes. " \
            "Read a candidate before turning it into a tester-facing case.",
        ]

        changes.map(&:name).map(&:to_s).reject(&:empty?).uniq.sort.each do |name|
          lines.concat(["", "## #{UntrustedText.escape(name.gsub(/\s+/, " "))}", ""])
          matches = paths_for(name)
          if matches.nil?
            lines << "Usage search failed; inspect repository files directly."
          elsif matches.empty?
            lines << "No application source file matched this package name. It may use another import name."
          else
            sampled = CallSiteSample.spread(matches.sort).first(MAX_FILES_PER_PACKAGE)
            sampled.each { |path| lines << "- #{UntrustedText.escape(path.gsub(/\s+/, " "))}" }
            lines << "- ...additional matches omitted" if matches.length > sampled.length
          end
        end

        lines << "\nNo in-scope dependency raises were found." if changes.empty?
        "#{lines.join("\n")}\n"
      end

    private

      def paths_for(name)
        patterns = [name, name.tr("-", "_"), name.tr("-", "/")].uniq
        arguments = ["git", "grep", "--no-color", "-l", "-F"]
        patterns.each { |pattern| arguments.concat(["-e", pattern]) }
        stdout, _stderr, status = Open3.capture3(
          *arguments, "--", *SEARCHED_EXTENSIONS, chdir: @workspace
        )
        return nil unless [0, 1].include?(status.exitstatus)

        CommandOutput.utf8(stdout).lines.map(&:chomp).reject(&:empty?).reject do |path|
          path.split("/").any? { |part| NON_APPLICATION_SEGMENTS.include?(part) }
        end
      rescue
        nil
      end
    end
  end
end
