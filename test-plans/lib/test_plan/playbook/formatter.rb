require_relative "../untrusted_text"

module TestPlan
  module Playbook
    # Renders the kit-organised plan. The coverage tier is decided here from the use
    # count rather than taken from the provider, so a sample can never be published as
    # exhaustive.
    class Formatter
      COMPLETE_COVERAGE_MAX = 4
      REGRESSION_BANNER = "**Every case below is a regression test.** This upgrade changes no " \
        "application code — only the Playbook version — so the goal is confirming that existing " \
        "behavior still holds, not exercising anything new."
      NO_KITS_MESSAGE = "No changed Playbook kits were identified for this upgrade."
      NO_CROSS_CUTTING_MESSAGE = "No Playbook changes outside the kits were identified."
      NO_OTHER_DEPENDENCIES_MESSAGE = "No other dependency raises in this PR."

      def initialize(parsed:, pull_request_title:, profile_name:, generation_warning: "")
        @parsed = parsed
        @pull_request_title = normalize_text(pull_request_title)
        @profile_name = normalize_text(profile_name)
        @generation_warning = normalize_text(generation_warning)
        @case_identifiers = build_case_identifiers
      end

      def render
        sections = [heading]
        sections << "> ⚠️ #{@generation_warning}" unless @generation_warning.empty?
        sections << discarded_notice unless @parsed.discarded.empty?
        sections.concat(
          [
            "> #{REGRESSION_BANNER}",
            "---",
            breadth_section,
            "---",
            kits_section,
            "---",
            beyond_section,
          ]
        )

        "#{sections.join("\n\n")}\n"
      end

    private

      def heading
        name = @profile_name.empty? ? "Test Plan" : @profile_name
        title_suffix = @pull_request_title.empty? ? "" : ": #{sanitize(@pull_request_title)}"
        "## ✅ #{name}#{title_suffix}"
      end

      def discarded_notice
        discarded = @parsed.discarded
        count = discarded.length
        lines = ["> ⚠️ #{count} #{count == 1 ? "part" : "parts"} of the generated response could not be used:"]
        discarded.first(5).each { |reason| lines << "> - #{sanitize(reason)}" }
        lines << "> - ...and #{count - 5} more" if count > 5
        lines.join("\n")
      end

      # The first question on a Playbook raise is how much of the application it touches
      # and whether a kit's list is exhaustive, so it is answered before any case.
      def breadth_section
        lines = ["## Coverage at a Glance", ""]
        return lines.push("- #{NO_KITS_MESSAGE}").join("\n") if @parsed.kits.empty?

        lines << "| Kit | Uses in app | Coverage | Cases |"
        lines << "| --- | --- | --- | --- |"
        @parsed.kits.each do |kit|
          lines << "| #{sanitize(kit.fetch("name"))} | #{kit.fetch("use_count")} | " \
            "#{coverage_label(kit)} | #{case_range(kit)} |"
        end
        lines.join("\n")
      end

      def kits_section
        lines = ["## Regression Coverage by Kit", ""]
        return lines.push("- #{NO_KITS_MESSAGE}").join("\n") if @parsed.kits.empty?

        @parsed.kits.each_with_index do |kit, index|
          lines << "" unless index.zero?
          lines << "### #{sanitize(kit.fetch("name"))} — #{use_count_label(kit)} · #{coverage_phrase(kit)}"
          lines << ""
          what_changed = sanitize(kit.fetch("what_changed"))
          unless what_changed.empty?
            lines << "**What changed:** #{what_changed}"
            lines << ""
          end
          lines << coverage_sentence(kit)

          kit.fetch("cases").each do |scenario|
            lines << ""
            lines << "#### #{@case_identifiers.fetch(scenario.object_id)} — #{sanitize(scenario.fetch("title"))}"
            lines << ""
            lines.concat(case_metadata(scenario))
            lines << ""
            scenario.fetch("steps").each { |step| lines << "- #{sanitize(step)}" }
          end
        end

        lines.join("\n")
      end

      # Access rather than a Permissions section of its own: a Playbook raise changes no
      # permissions, but a tester still has to be able to reach the page.
      def case_metadata(scenario)
        rows = []
        page = sanitize(scenario.fetch("page"))
        source = sanitize(scenario.fetch("source"))
        access = sanitize(scenario.fetch("access"))
        rows << "**Page:** #{page}  " unless page.empty?
        rows << "**Source:** #{source}  " unless source.empty?
        rows << "**Access:** #{access}  " unless access.empty?
        rows.empty? ? ["**Page:** Not identified from this change."] : rows
      end

      def beyond_section
        lines = ["## Beyond the Kits", "", "### Playbook changes not scoped to a kit", ""]

        if @parsed.cross_cutting.empty?
          lines << "- #{NO_CROSS_CUTTING_MESSAGE}"
        else
          @parsed.cross_cutting.each_with_index do |entry, index|
            lines << "" unless index.zero?
            lines << "**#{sanitize(entry.fetch("area"))}**"
            paths = entry.fetch("paths")
            lines << "" << paths.map { |path| "`#{sanitize(path)}`" }.join(", ") unless paths.empty?
            risk = sanitize(entry.fetch("risk"))
            lines << "" << risk unless risk.empty?
            steps = entry.fetch("steps")
            lines << "" unless steps.empty?
            steps.each { |step| lines << "- #{sanitize(step)}" }
          end
        end

        lines << ""
        lines << "### Other dependency raises in this PR"
        lines << ""

        if @parsed.other_dependencies.empty?
          lines << "- #{NO_OTHER_DEPENDENCIES_MESSAGE}"
        else
          @parsed.other_dependencies.each do |entry|
            lines << "- **#{sanitize(entry.fetch("name"))} #{version_range(entry)}** — #{dependency_note(entry)}"
            entry.fetch("steps").each { |step| lines << "  - #{sanitize(step)}" }
          end
        end

        lines.join("\n")
      end

      def version_range(entry)
        from = sanitize(entry.fetch("from"))
        to = sanitize(entry.fetch("to"))
        return "" if from.empty? || to.empty?

        "#{from} → #{to}"
      end

      def dependency_note(entry)
        note = sanitize(entry.fetch("note"))
        note.empty? ? "Raised alongside the Playbook upgrade." : note
      end

      def complete?(kit)
        kit.fetch("use_count") <= COMPLETE_COVERAGE_MAX
      end

      def coverage_label(kit)
        complete?(kit) ? "Complete" : "Representative"
      end

      def coverage_phrase(kit)
        complete?(kit) ? "complete coverage" : "representative sample"
      end

      def use_count_label(kit)
        count = kit.fetch("use_count")
        "#{count} #{count == 1 ? "use" : "uses"}"
      end

      def coverage_sentence(kit)
        cases = kit.fetch("cases").length
        return "**Coverage:** every use in this repository is listed below. Nothing is sampled." if complete?(kit)

        "**Coverage:** used in #{kit.fetch("use_count")} files across the application. Testing " \
          "every use is not practical; the #{cases} #{cases == 1 ? "page" : "pages"} below are a " \
          "**representative sample**. If they hold, treat the kit as covered."
      end

      def case_range(kit)
        identifiers = kit.fetch("cases").map { |scenario| @case_identifiers.fetch(scenario.object_id) }
        return identifiers.first.to_s if identifiers.length == 1

        "#{identifiers.first} – #{identifiers.last}"
      end

      def build_case_identifiers
        code_counts = Hash.new(0)

        @parsed.kits.each_with_object({}) do |kit, identifiers|
          kit.fetch("cases").each do |scenario|
            code = kit.fetch("code")
            code_counts[code] += 1
            identifiers[scenario.object_id] = "#{code}-#{code_counts[code]}"
          end
        end
      end

      def sanitize(value)
        UntrustedText.escape(value)
      end

      def normalize_text(value)
        value.to_s.strip.gsub(/\s+/, " ")
      end
    end
  end
end
