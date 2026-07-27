#!/usr/bin/env ruby

class AcceptanceCriteriaFormatter
  NO_MANUAL_QA_MESSAGE = "No manual application QA was identified for this change."
  NO_REGRESSION_MESSAGE = "No targeted regression testing was identified for this change."
  NO_ROLES_MESSAGE = "Not identified from this change."

  PERMISSION_LABELS = {
    "yes" => "Yes",
    "no" => "No",
    "not_identified" => "Not identified",
  }.freeze

  def initialize(parsed:, pull_request_number:, pull_request_title:)
    @parsed = parsed
    @pull_request_number = pull_request_number
    @pull_request_title = normalize_text(pull_request_title)
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
    title_suffix = @pull_request_title.empty? ? "" : " — #{@pull_request_title}"
    "## ✅ Test Plan: PR ##{@pull_request_number}#{title_suffix}"
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

    lines.join("\n")
  end

  def features_section
    lines = ["### Functional / Features to Test", ""]

    if @parsed.feature_areas.empty?
      lines << "- #{NO_MANUAL_QA_MESSAGE}"
      return lines.join("\n")
    end

    code_counts = Hash.new(0)
    @parsed.feature_areas.each_with_index do |area, area_index|
      lines << "" unless area_index.zero?
      lines << feature_heading(area)
      lines << ""

      area.fetch("scenarios").each_with_index do |scenario, scenario_index|
        lines << "" unless scenario_index.zero?
        code = area.fetch("code")
        code_counts[code] += 1
        lines << "- **#{code}-#{code_counts[code]} — #{scenario.fetch("title")}**"
        scenario.fetch("steps").each { |step| lines << "  - #{step}" }
      end
    end

    lines.join("\n")
  end

  def feature_heading(area)
    location = area.fetch("location").delete("`")
    suffix = location.empty? ? "" : " — `#{location}`"
    "#### #{area.fetch("name")}#{suffix}"
  end

  def regression_section
    lines = ["### Regression Testing", ""]

    if @parsed.regression_tests.empty?
      lines << "- #{NO_REGRESSION_MESSAGE}"
      return lines.join("\n")
    end

    @parsed.regression_tests.each do |test|
      lines << "- #{test.fetch("text")}"
      test.fetch("details").each { |detail| lines << "  - #{detail}" }
    end

    lines.join("\n")
  end

  def normalize_text(value)
    value.to_s.strip.gsub(/\s+/, " ")
  end
end
