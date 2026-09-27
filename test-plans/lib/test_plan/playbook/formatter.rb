require_relative "../untrusted_text"
require_relative "./kit_facts"

module TestPlan
  module Playbook
    # Renders the kit-organised plan. The coverage tier is decided here from the use
    # count rather than taken from the provider, so a sample can never be published as
    # exhaustive.
    class Formatter
      REGRESSION_BANNER = "**Every kit case below is a regression test.** The Playbook raise " \
        "calls for confirming that existing behavior still holds."
      NO_KITS_MESSAGE = "No changed Playbook kits were identified for this upgrade."
      NO_OTHER_DEPENDENCIES_MESSAGE = "No other dependency raises in this PR."

      def initialize(parsed:, pull_request_title:, profile_name:, generation_warning: "",
                     kit_facts: KitFacts.none, manifest: { "dependencies" => [] })
        @parsed = parsed
        @kit_facts = kit_facts
        @pull_request_title = normalize_text(pull_request_title)
        @profile_name = normalize_text(profile_name)
        @generation_warning = normalize_text(generation_warning)
        @case_identifiers = build_case_identifiers
        @manifest_dependencies = manifest.fetch("dependencies")
        @playbook_raises = @manifest_dependencies.select do |entry|
          %w[playbook_ui playbook-ui].include?(entry.fetch("name"))
        end
      end

      def render
        sections = [heading]
        sections << "> ⚠️ #{@generation_warning}" unless @generation_warning.empty?
        sections << discarded_notice unless @parsed.discarded.empty?
        sections.concat(
          [
            "> #{REGRESSION_BANNER}",
            "---",
            release_section,
            "---",
            kits_section,
            "---",
            beyond_section,
          ]
        )
        sections.concat(["---", checks_section("Additional Playbook Regression Testing", @parsed.regression_tests)]) unless @parsed.regression_tests.empty?
        sections.concat(["---", checks_section("Application Compatibility Checks", @parsed.application_checks)]) unless @parsed.application_checks.empty?

        "#{sections.join("\n\n")}\n"
      end

    private

      def release_section
        lines = ["## Playbook version changes", ""]
        @playbook_raises.each do |entry|
          lines << "- **#{sanitize(entry.fetch("name"))} " \
            "#{sanitize(entry.fetch("old_version"))} → #{sanitize(entry.fetch("new_version"))}**"
        end
        lines << "- Playbook version details were unavailable." if @playbook_raises.empty?
        lines.join("\n")
      end

      def checks_section(title, checks)
        lines = ["## #{title}", ""]
        checks.each do |check|
          lines << "### #{sanitize(check.fetch("title"))}"
          page = sanitize(check.fetch("page"))
          lines << "**Page:** #{page}" unless page.empty?
          lines << ""
          check.fetch("steps").each { |step| lines << "- #{sanitize(step)}" }
          lines << ""
        end
        lines.join("\n")
      end

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

      def kits_section
        lines = ["## Regression Coverage by Kit", ""]
        return lines.push("- #{NO_KITS_MESSAGE}").join("\n") if @parsed.kits.empty?

        @parsed.kits.each_with_index do |kit, index|
          lines << "" unless index.zero?
          lines << "### #{sanitize(kit.fetch("name"))}#{changed_in(kit)}"
          lines << ""
          what_changed = sanitize(kit.fetch("what_changed"))
          unless what_changed.empty?
            lines << "**What changed:** #{what_changed}"
            lines << ""
          end
          lines << "**Coverage:** #{KitFacts.sentence(coverage(kit))}"
          unsearched = systems_not_in_use(kit)
          unless unsearched.empty?
            lines << ""
            lines << "This upgrade changed the #{KitFacts.systems_label(unsearched)} side of this " \
              "kit, but nothing in this repository renders it."
          end

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

      # A kit is two implementations sharing a name, so which one a case exercises is the
      # difference between a tester opening the right page and the wrong one.
      def case_metadata(scenario)
        rows = []
        page = sanitize(scenario.fetch("page"))
        system = KitFacts::SYSTEM_LABELS[scenario.fetch("system")]
        rows << "**Page:** #{page}  " unless page.empty?
        rows << "**System:** #{system}  " if system
        rows.empty? ? ["**Page:** Not identified from this change."] : rows
      end

      # Only the dependency raises. A Playbook release also moves its own version constant,
      # its packaging and its documentation site, and writing those up spent tokens on
      # changes no tester can act on.
      def beyond_section
        lines = ["## Other dependency raises in this PR", ""]
        entries = other_dependencies

        if entries.empty?
          lines << "- #{NO_OTHER_DEPENDENCIES_MESSAGE}"
        else
          entries.each do |entry|
            lines << "- **#{sanitize(entry.fetch("name"))} #{version_range(entry)}** — #{dependency_note(entry)}"
            entry.fetch("steps").each { |step| lines << "  - #{sanitize(step)}" }
          end
        end

        lines.join("\n")
      end

      def other_dependencies
        return @parsed.other_dependencies if @manifest_dependencies.empty?

        @manifest_dependencies.reject { |entry| %w[playbook_ui playbook-ui].include?(entry.fetch("name")) }
          .map do |entry|
            name = entry.fetch("name")
            from = entry.fetch("old_version")
            to = entry.fetch("new_version")
            annotation = @parsed.other_dependencies.find do |candidate|
              candidate.fetch("name") == name && candidate.fetch("from") == from && candidate.fetch("to") == to
            end
            {
              "name" => name, "from" => from, "to" => to,
              "note" => annotation&.fetch("note") || "No behavior-specific note was provided.",
              "steps" => annotation&.fetch("steps") || [],
            }
          end
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

      def fact_for(kit)
        @kit_facts.for(slug: kit.fetch("slug"), name: kit.fetch("name"))
      end

      # Never upgraded on the provider's word. Without a matching fact the plan reads as a
      # sample, which under-claims; and a kit the action found exhaustible is downgraded
      # anyway when the provider wrote fewer cases than there are call sites, because
      # "every use is listed below" would then be false.
      def coverage(kit)
        fact = fact_for(kit)
        return KitFacts::REPRESENTATIVE unless fact

        coverage = fact.fetch("coverage", KitFacts::REPRESENTATIVE)
        return coverage unless coverage == KitFacts::COMPLETE
        return KitFacts::REPRESENTATIVE if fact.fetch("call_sites", 0) > kit.fetch("cases").length

        coverage
      end

      def changed_in(kit)
        label = KitFacts.systems_label(fact_for(kit)&.fetch("systems_changed") { [] } || [])
        label.empty? ? "" : " — #{label}"
      end

      def systems_not_in_use(kit)
        fact = fact_for(kit)
        return [] unless fact

        fact.fetch("systems_changed", []) - fact.fetch("systems_in_use", [])
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
