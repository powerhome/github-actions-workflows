module TestPlan
  class Formatter
    NO_MANUAL_QA_MESSAGE = "No manual application QA was identified for this change."
    NO_REGRESSION_MESSAGE = "No targeted regression testing was identified for this change."
    NO_ROLES_MESSAGE = "Not identified from this change."
    NO_SUBJECT_ACTIONS_MESSAGE = "Not identified from this change."

    PERMISSION_LABELS = {
      "yes" => "Yes",
      "no" => "No",
      "not_identified" => "Not identified",
    }.freeze

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
      sections.concat(
        [
          "---",
          permissions_section,
          "---",
          features_section,
          "---",
          regression_section,
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

    def permissions_section
      lines = [
        "## Permissions / Roles",
        "",
        "- **Required Permissions:** #{PERMISSION_LABELS.fetch(@parsed.permissions.fetch("required"))}",
      ]

      permission_changes = @parsed.permissions.fetch("changes")
      unless permission_changes.empty?
        lines << "- **Permission Changes in This PR:**"
        permission_changes.each { |change| lines << "  - #{sanitize(change)}" }
      end

      roles = @parsed.permissions.fetch("roles")
      if roles.empty?
        roles_message = @parsed.permissions.fetch("required") == "no" ? "No special role required." : NO_ROLES_MESSAGE
        lines << "- **Roles to Test:** #{roles_message}"
      else
        lines << "- **Roles to Test:**"
        roles.each { |role| lines << "  - #{sanitize(role)}" }
      end

      subject_actions = @parsed.permissions.fetch("subject_actions")
      if subject_actions.empty?
        subject_actions_message = @parsed.permissions.fetch("required") == "no" ? "No special permission required." : NO_SUBJECT_ACTIONS_MESSAGE
        lines << "- **Permission Subjects / Actions:** #{subject_actions_message}"
      else
        lines << "- **Permission Subjects / Actions:**"
        subject_actions.each { |permission| lines << "  - #{permission_display(permission)}" }
      end

      lines.join("\n")
    end

    def features_section
      lines = ["## Functional / Features to Test", ""]

      if @parsed.feature_areas.empty?
        lines << "- #{NO_MANUAL_QA_MESSAGE}"
        return lines.join("\n")
      end

      @parsed.feature_areas.each_with_index do |area, area_index|
        lines << "" unless area_index.zero?
        lines << feature_heading(area)
        lines << ""

        area.fetch("scenarios").each_with_index do |scenario, scenario_index|
          lines << "" unless scenario_index.zero?
          identifier = @case_identifiers.fetch(scenario.object_id)
          lines << "#### #{identifier} — #{sanitize(scenario.fetch("title"))}"
          lines << ""
          lines << "**Landing Page:** #{format_landing_page(scenario.fetch("landing_page"))}  "
          audience = sanitize(scenario.fetch("audience"))
          # Only rendered where the application actually serves more than one audience;
          # a single-audience application would otherwise carry a "not identified" line
          # on every case.
          lines << "**Audience:** #{audience}  " unless audience.empty?
          lines << "**Permissions:** #{scenario_permissions(scenario)}"
          lines << ""
          scenario.fetch("steps").each { |step| lines << "- #{sanitize(step)}" }
        end
      end

      lines.join("\n")
    end

    def feature_heading(area)
      domain = sanitize(area.fetch("domain"))
      suffix = domain.empty? ? "" : " — #{domain}"
      "### #{sanitize(area.fetch("test_path"))}#{suffix}"
    end

    def regression_section
      lines = ["## Regression Testing", ""]
      applicable_cases = regression_case_identifiers

      if applicable_cases.empty? && @parsed.regression_tests.empty?
        lines << "- #{NO_REGRESSION_MESSAGE}"
        return lines.join("\n")
      end

      unless applicable_cases.empty?
        lines << "- **Applicable Functional Cases:** #{applicable_cases.join(", ")}"
        lines << "" unless @parsed.regression_tests.empty?
      end

      @parsed.regression_tests.each do |test|
        lines << "- #{sanitize(test.fetch("text"))}"
        test.fetch("details").each { |detail| lines << "  - #{sanitize(detail)}" }
      end

      lines.join("\n")
    end

    def build_case_identifiers
      code_counts = Hash.new(0)

      @parsed.feature_areas.each_with_object({}) do |area, identifiers|
        area.fetch("scenarios").each do |scenario|
          code = area.fetch("code")
          code_counts[code] += 1
          identifiers[scenario.object_id] = "#{code}-#{code_counts[code]}"
        end
      end
    end

    def regression_case_identifiers
      @parsed.feature_areas.flat_map do |area|
        area.fetch("scenarios").filter_map do |scenario|
          @case_identifiers.fetch(scenario.object_id) if scenario.fetch("include_in_regression")
        end
      end
    end

    def scenario_permissions(scenario)
      permissions = scenario.fetch("permissions")
      if permissions.empty?
        return @parsed.permissions.fetch("required") == "no" ? "No special permission required." : "Not identified for this case."
      end

      permissions.map { |permission| permission_display(permission) }.join("; ")
    end

    def permission_display(permission)
      subject = sanitize(permission.fetch("subject"))
      action = sanitize(permission.fetch("action"))
      "#{subject} — #{action}"
    end

    def format_landing_page(value)
      landing_page = sanitize(value)
      landing_page.empty? ? "Not identified from this change." : landing_page
    end

    # Everything the provider returns, and the pull-request title, is untrusted text
    # rendered into a comment the bot signs. Left raw, a step or a title could carry an
    # @mention that notifies people, a link or image pointing anywhere, or inline HTML.
    # The plan's own structure is built by this formatter, so provider text never needs
    # to carry markup and can be neutralised wholesale.
    #
    # &#64; renders as @ without becoming a mention; the escapes leave the reader with
    # the characters that were written.
    def sanitize(value)
      value
        .to_s
        .delete("`")
        .gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub("@", "&#64;")
        .gsub(/([\[\]])/) { "\\#{Regexp.last_match(1)}" }
    end

    def normalize_text(value)
      value.to_s.strip.gsub(/\s+/, " ")
    end
  end
end
