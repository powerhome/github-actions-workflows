require_relative "../untrusted_text"

module TestPlan
  module Dependency
    class Formatter
      NO_REGRESSION_MESSAGE = "No tester-visible use could be established from the available evidence."

      def initialize(parsed:, manifest:, pull_request_title:, profile_name:, generation_warning: "")
        @parsed = parsed
        @manifest_dependencies = manifest.fetch("dependencies")
        @pull_request_title = normalize(pull_request_title)
        @profile_name = normalize(profile_name)
        @generation_warning = normalize(generation_warning)
      end

      def render
        sections = [heading]
        sections << "> ⚠️ #{@generation_warning}" unless @generation_warning.empty?
        sections << discarded_notice unless @parsed.discarded.empty?
        sections.concat([
          "> This plan checks existing behavior after dependency version changes.",
          "---", dependency_section, "---", regression_section,
        ])
        sections.concat(["---", application_section]) unless @parsed.application_checks.empty?
        "#{sections.join("\n\n")}\n"
      end

    private

      def heading
        name = @profile_name.empty? ? "Test Plan" : @profile_name
        suffix = @pull_request_title.empty? ? "" : ": #{sanitize(@pull_request_title)}"
        "## ✅ #{name}#{suffix}"
      end

      def dependency_section
        lines = ["## Dependency version changes", ""]
        @manifest_dependencies.each do |entry|
          annotation = annotation_for(entry)
          label = "#{sanitize(entry.fetch("name"))} (#{sanitize(entry.fetch("ecosystem"))})"
          version = "#{sanitize(entry.fetch("old_version"))} → #{sanitize(entry.fetch("new_version"))}"
          note = annotation && !annotation.fetch("note").empty? ? annotation.fetch("note") : fallback_note(entry)
          lines << "- **#{label} #{version}** — #{sanitize(note)}"
          Array(annotation&.fetch("steps", [])).each { |step| lines << "  - #{sanitize(step)}" }
        end
        lines.join("\n")
      end

      def annotation_for(entry)
        @parsed.dependencies.find do |candidate|
          candidate.fetch("ecosystem") == entry.fetch("ecosystem") &&
            candidate.fetch("name") == entry.fetch("name") &&
            candidate.fetch("source") == entry.fetch("source") &&
            candidate.fetch("from") == entry.fetch("old_version") &&
            candidate.fetch("to") == entry.fetch("new_version")
        end
      end

      def fallback_note(entry)
        entry.fetch("status") == "unavailable" ?
          "Upstream delta unavailable; no behavior-specific claim can be made." :
          "No behavior-specific note was provided."
      end

      def regression_section
        lines = ["## Regression Testing", ""]
        names = @manifest_dependencies.map { |entry| entry.fetch("name") }
        cases = @parsed.regression_tests.select { |test| names.include?(test.fetch("dependency")) }
        return lines.push("- #{NO_REGRESSION_MESSAGE}").join("\n") if cases.empty?

        cases.each { |test| lines.concat(case_lines(test, dependency: true)) }
        lines.join("\n")
      end

      def application_section
        lines = ["## Application Compatibility Checks", ""]
        @parsed.application_checks.each { |test| lines.concat(case_lines(test)) }
        lines.join("\n")
      end

      def case_lines(test, dependency: false)
        lines = ["### #{sanitize(test.fetch("title"))}", ""]
        lines << "**Dependency:** #{sanitize(test.fetch("dependency"))}  " if dependency
        page = sanitize(test.fetch("page"))
        lines << "**Page:** #{page}  " unless page.empty?
        lines << ""
        test.fetch("steps").each { |step| lines << "- #{sanitize(step)}" }
        lines << ""
        lines
      end

      def discarded_notice
        count = @parsed.discarded.length
        lines = ["> ⚠️ #{count} #{count == 1 ? "part" : "parts"} of the generated response could not be used:"]
        @parsed.discarded.first(5).each { |reason| lines << "> - #{sanitize(reason)}" }
        lines << "> - ...and #{count - 5} more" if count > 5
        lines.join("\n")
      end

      def sanitize(value)
        UntrustedText.escape(value)
      end

      def normalize(value)
        value.to_s.strip.gsub(/\s+/, " ")
      end
    end
  end
end
