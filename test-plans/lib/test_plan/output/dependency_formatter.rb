require_relative "plan_document"

module TestPlan
  module Output
    # The list of raises is the manifest's, not the provider's, so a raise the response
    # omitted still appears and one it invented does not.
    class DependencyFormatter
      include PlanDocument

      NO_REGRESSION_MESSAGE = "No tester-visible use could be established from the available evidence."
      NO_NOTE_MESSAGE = "No behavior-specific note was provided."
      UNAVAILABLE_NOTE_MESSAGE = "Upstream delta unavailable; no behavior-specific claim can be made."

      def initialize(parsed:, manifest:, pull_request_title:, profile_name:, generation_warning: "")
        @parsed = parsed
        @manifest_dependencies = manifest.fetch("dependencies")
        @pull_request_title = normalize_text(pull_request_title)
        @profile_name = normalize_text(profile_name)
        @generation_warning = normalize_text(generation_warning)
        @regression_cases, @unnamed_cases = partition_regression_tests
      end

      def render
        sections = preamble
        sections.concat([
                          "> This plan checks existing behavior after dependency version changes.",
                          "---", dependency_section, "---", regression_section,
                        ])
        sections.concat(["---", application_section]) unless @parsed.application_checks.empty?
        "#{sections.join("\n\n")}\n"
      end

    private

      # Dropped -- it is not testing the raise -- but dropped out loud, since a plan that
      # quietly published fewer cases than were generated reads as complete.
      def partition_regression_tests
        names = @manifest_dependencies.map { |entry| entry.fetch("name") }

        @parsed.regression_tests.partition { |test| names.include?(test.fetch("dependency")) }
      end

      def discarded
        @discarded ||= @parsed.discarded + @unnamed_cases.map do |test|
          "regression test #{test.fetch("title").inspect} named #{test.fetch("dependency").inspect}, " \
            "which this pull request did not raise"
        end
      end

      def dependency_section
        lines = ["## Dependency version changes", ""]
        @manifest_dependencies.each do |entry|
          annotation = annotation_for(entry)
          label = "#{sanitize(entry.fetch("name"))} (#{sanitize(entry.fetch("ecosystem"))})"
          version = "#{sanitize(entry.fetch("old_version"))} → #{sanitize(entry.fetch("new_version"))}"
          lines << "- **#{label} #{version}** — #{sanitize(note_for(entry, annotation))}"
          Array(annotation&.fetch("steps")).each { |step| lines << "  - #{sanitize(step)}" }
        end
        lines.join("\n")
      end

      # Deliberately not matched on `source`: an internal enum the provider sees only in
      # the manifest, where spelling it "rubygems.org" would cost this raise its note.
      def annotation_for(entry)
        @parsed.dependencies.find do |candidate|
          candidate.fetch("ecosystem") == entry.fetch("ecosystem") &&
            candidate.fetch("name") == entry.fetch("name") &&
            candidate.fetch("from") == entry.fetch("old_version") &&
            candidate.fetch("to") == entry.fetch("new_version")
        end
      end

      # Silence is not evidence of no change, and its two reasons differ to a tester:
      # nothing was retrieved, or something was and nothing was said about it.
      def note_for(entry, annotation)
        note = annotation ? annotation.fetch("note") : ""
        return note unless note.empty?

        entry.fetch("status", "") == "unavailable" ? UNAVAILABLE_NOTE_MESSAGE : NO_NOTE_MESSAGE
      end

      def regression_section
        lines = ["## Regression Testing", ""]
        return lines.push("- #{NO_REGRESSION_MESSAGE}").join("\n") if @regression_cases.empty?

        @regression_cases.each { |test| lines.concat(case_lines(test, dependency: true)) }
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
    end
  end
end
