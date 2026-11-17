#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks ADRs and CIRs against RFC 0110. Runs from the action, or on its own anywhere Ruby
# 3.1+ is installed, such as a Jenkins stage:
#
#   ruby check_decision_records.rb --adr docs/decisions --cir docs/cir --mkdocs mkdocs.yml
#
# In the action, DECISION_RECORDS_ADR_DIRS and DECISION_RECORDS_CIR_DIRS hold one
# directory per line, and DECISION_RECORDS_MKDOCS the MkDocs config, or nothing.

require "optparse"
require_relative "../lib/decision_records"

def lines(value)
  value.to_s.lines.map(&:strip).reject(&:empty?)
end

options = {
  root: ENV.fetch("GITHUB_WORKSPACE", Dir.pwd),
  adr_dirs: lines(ENV.fetch("DECISION_RECORDS_ADR_DIRS", nil)),
  cir_dirs: lines(ENV.fetch("DECISION_RECORDS_CIR_DIRS", nil)),
  mkdocs: ENV.fetch("DECISION_RECORDS_MKDOCS", "").strip
}

OptionParser.new do |parser|
  parser.banner = "Usage: check_decision_records.rb [--adr DIR]... [--cir DIR]... [--mkdocs FILE] [--root DIR]"
  parser.on("--adr DIR", "A directory of ADRs (repeatable)") { |dir| options[:adr_dirs] << dir }
  parser.on("--cir DIR", "A directory of CIRs (repeatable)") { |dir| options[:cir_dirs] << dir }
  parser.on("--mkdocs FILE", "MkDocs config whose nav must list every record it lists any of") do |file|
    options[:mkdocs] = file
  end
  parser.on("--root DIR", "Repository root (default: GITHUB_WORKSPACE or the working directory)") do |dir|
    options[:root] = dir
  end
end.parse!

options[:mkdocs] = nil if options[:mkdocs].to_s.empty?
if options[:adr_dirs].empty? && options[:cir_dirs].empty?
  warn "Nothing to check: give at least one ADR or CIR directory."
  exit 2
end

problems = DecisionRecords.check(**options)
annotate = ENV["GITHUB_ACTIONS"] == "true"

problems.each do |problem|
  if annotate
    puts "::error file=#{problem.path}::#{problem.message}"
  else
    warn problem
  end
end

checked = (options[:adr_dirs] + options[:cir_dirs]).join(", ")
if problems.empty?
  puts "Decision records in #{checked} follow RFC 0110."
else
  warn "#{problems.size} problem(s) in #{checked}. See https://github.com/powerhome/rfcs/pull/240 for the format."
  exit 1
end
