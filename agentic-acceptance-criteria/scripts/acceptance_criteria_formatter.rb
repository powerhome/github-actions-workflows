#!/usr/bin/env ruby

class AcceptanceCriteriaFormatter
  NO_MANUAL_QA_MESSAGE = "No manual application QA was identified for this change."
  NO_REGRESSION_MESSAGE = "No targeted regression testing was identified for this change."
  NO_ROLES_MESSAGE = "Not identified from this change."
  NO_SUBJECT_ACTIONS_MESSAGE = "Not identified from this change."

  PERMISSION_LABELS = {
    "yes" => "Yes",
    "no" => "No",
    "not_identified" => "Not identified",
  }.freeze

  def initialize(parsed:, pull_request_title:)
    @parsed = parsed
    @pull_request_title = normalize_text(pull_request_title)
    @case_identifiers = build_case_identifiers
  end

  def render
    sections = [
      heading,
      "---",
      permissions_section,
      "---",
      features_section,
      "---",
      regression_section,
    ]

    "#{sections.join("\n\n")}\n"
  end

private

  def heading
    title_suffix = @pull_request_title.empty? ? "" : ": #{@pull_request_title}"
    "## ✅ Test Plan#{title_suffix}"
  end

  def permissions_section
    lines = [
      "### Permissions / Roles",
      "",
      "- **Required Permissions:** #{PERMISSION_LABELS.fetch(@parsed.permissions.fetch("required"))}",
    ]

    roles = @parsed.permissions.fetch("roles")
    if roles.empty?
      roles_message = @parsed.permissions.fetch("required") == "no" ? "No special role required." : NO_ROLES_MESSAGE
      lines << "- **Roles to Test:** #{roles_message}"
    else
      lines << "- **Roles to Test:**"
      roles.each { |role| lines << "  - #{role}" }
    end

    subject_actions = @parsed.permissions.fetch("subject_actions")
    if subject_actions.empty?
      subject_actions_message = @parsed.permissions.fetch("required") == "no" ? "No special permission required." : NO_SUBJECT_ACTIONS_MESSAGE
      lines << "- **Permission Subjects / Actions:** #{subject_actions_message}"
    else
      lines << "- **Permission Subjects / Actions:**"
      subject_actions.each { |permission| lines << permission_line(permission, "  ") }
    end

    lines.join("\n")
  end

  def features_section
    lines = ["### Functional / Features to Test", ""]

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
        lines << "- **#{identifier} — #{scenario.fetch("title")}**"
        lines << "  - **Landing Page:** #{format_landing_page(scenario.fetch("landing_page"))}"
        lines.concat(scenario_permission_lines(scenario))
        scenario.fetch("steps").each { |step| lines << "  - #{step}" }
      end
    end

    lines.join("\n")
  end

  def feature_heading(area)
    domain = area.fetch("domain")
    suffix = domain.empty? ? "" : " — #{domain}"
    "#### #{area.fetch("test_path")}#{suffix}"
  end

  def regression_section
    lines = ["### Regression Testing", ""]
    applicable_cases = regression_case_identifiers

    if applicable_cases.empty? && @parsed.regression_tests.empty?
      lines << "- #{NO_REGRESSION_MESSAGE}"
      return lines.join("\n")
    end

    unless applicable_cases.empty?
      lines << "- **Applicable Functional Cases:** #{applicable_cases.join(", ")}"
    end

    @parsed.regression_tests.each do |test|
      lines << "- #{test.fetch("text")}"
      test.fetch("details").each { |detail| lines << "  - #{detail}" }
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

  def scenario_permission_lines(scenario)
    permissions = scenario.fetch("permissions")
    if permissions.empty?
      message = @parsed.permissions.fetch("required") == "no" ? "No special permission required." : "Not identified for this case."
      return ["  - **Permissions:** #{message}"]
    end

    [
      "  - **Permissions:**",
      *permissions.map { |permission| permission_line(permission, "    ") },
    ]
  end

  def permission_line(permission, indentation)
    subject = permission.fetch("subject").delete("`")
    action = permission.fetch("action").delete("`")
    "#{indentation}- **Subject:** `#{subject}`; **Action:** `#{action}`"
  end

  def format_landing_page(value)
    landing_page = value.delete("`")
    landing_page.empty? ? "Not identified from this change." : "`#{landing_page}`"
  end

  def normalize_text(value)
    value.to_s.strip.gsub(/\s+/, " ")
  end
end
