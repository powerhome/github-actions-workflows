# frozen_string_literal: true

require "date"
require "pathname"
require "yaml"

# Checks a repository's decision records against RFC 0116: ADRs in MADR 4.0.0 format and
# change intent records (CIRs) in their published format, each numbered NNNN-title.md.
#
# The checks are deliberately mechanical. Whether a record says something sensible is for
# review; whether its number is unique, its metadata parses and its links resolve is not.
module DecisionRecords
  Problem = Struct.new(:path, :message, keyword_init: true) do
    def to_s
      "#{path}: #{message}"
    end
  end

  FILE_NAME = /\A(?<number>\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md\z/
  # Pages in a records directory that are not records.
  ADR_EXEMPT = %w[README.md index.md adr-template.md].freeze
  CIR_EXEMPT = %w[README.md index.md cir-template.md].freeze

  ADR_STATUSES = %w[proposed accepted rejected deprecated].freeze
  ADR_SUPERSEDED = /\Asuperseded by ADR-(?<number>\d{4})\z/
  ADR_KEYS = %w[status date decision-makers consulted informed].freeze
  ADR_SECTIONS = ["Context and Problem Statement", "Considered Options", "Decision Outcome"].freeze

  CIR_TITLE = /\A# CIR-(?<number>\d{4}): \S/
  CIR_SECTIONS = %w[Intent Behavior Constraints Decisions Date].freeze
  CIR_SUPERSEDES = /^Supersedes: CIR-(?<number>\d{4})\s*$/

  ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

module_function

  # Returns the problems found in the given ADR and CIR directories, and in the MkDocs
  # navigation if `mkdocs` names a config file that lists record pages one by one.
  def check(root:, adr_dirs: [], cir_dirs: [], mkdocs: nil)
    root = Pathname.new(root)
    problems = []
    adr_dirs.each { |dir| problems.concat(check_adr_dir(root, dir)) }
    cir_dirs.each { |dir| problems.concat(check_cir_dir(root, dir)) }
    problems.concat(check_nav(root, mkdocs, adr_dirs + cir_dirs)) if mkdocs
    problems
  end

  def check_adr_dir(root, dir)
    records, problems = records_in(root, dir, ADR_EXEMPT)
    numbers = records.keys
    records.each_value do |files|
      files.each do |path|
        problems.concat(check_adr(root, path, numbers))
      end
    end
    problems
  end

  def check_cir_dir(root, dir)
    records, problems = records_in(root, dir, CIR_EXEMPT)
    numbers = records.keys
    records.each do |number, files|
      files.each do |path|
        problems.concat(check_cir(root, path, number, numbers))
      end
    end
    problems
  end

  # Groups a directory's records by number, reporting misnamed files and shared numbers.
  def records_in(root, dir, exempt)
    directory = root.join(dir)
    return [{}, [Problem.new(path: dir, message: "directory does not exist")]] unless directory.directory?

    problems = []
    records = Hash.new { |hash, key| hash[key] = [] }
    directory.children.select(&:file?).sort.each do |path|
      name = path.basename.to_s
      next if exempt.include?(name) || !name.end_with?(".md")

      match = FILE_NAME.match(name)
      if match
        records[match[:number]] << path
      else
        problems << Problem.new(path: relative(root, path),
                                message: "file name must be NNNN-title-with-dashes.md, in lower case")
      end
    end

    next_free = format("%04d", (records.keys.map(&:to_i).max || 0) + 1)
    records.each do |number, files|
      next if files.size == 1

      names = files.map { |path| path.basename.to_s }.join(", ")
      files.drop(1).each do |path|
        problems << Problem.new(path: relative(root, path),
                                message: "number #{number} is shared by #{names}; " \
                                         "renumber the later record to #{next_free}, the next number")
      end
    end
    problems.concat(gaps(root, records))
    [records, problems]
  end

  # The series runs from 0001 with no gaps. A missing number usually means a record took
  # a number ahead of the default branch, so it is reported against the record after it.
  def gaps(root, records)
    present = records.keys.map(&:to_i).reject(&:zero?).sort
    return [] if present.empty?

    ((1..present.last).to_a - present).map do |missing|
      above = present.find { |number| number > missing }
      path = records.fetch(format("%04d", above)).first
      Problem.new(path: relative(root, path),
                  message: "number #{format('%04d', missing)} is missing before this record; " \
                           "number records from the highest on the default branch, with no gaps")
    end
  end

  def check_adr(root, path, numbers)
    where = relative(root, path)
    text = path.read(encoding: Encoding::UTF_8)
    front_matter, body = split_front_matter(text)
    return [Problem.new(path: where, message: "missing YAML front matter between --- lines")] unless front_matter

    metadata = begin
      YAML.safe_load(front_matter, permitted_classes: [Date]) || {}
    rescue Psych::Exception => e
      return [Problem.new(path: where, message: "front matter is not valid YAML: #{e.message}")]
    end
    return [Problem.new(path: where, message: "front matter must be a YAML mapping")] unless metadata.is_a?(Hash)

    problems = []
    problems.concat(check_adr_metadata(where, metadata, numbers))
    problems.concat(check_adr_body(where, body))
    problems
  end

  def check_adr_metadata(where, metadata, numbers)
    problems = []
    unknown = metadata.keys - ADR_KEYS
    unless unknown.empty?
      problems << Problem.new(path: where, message: "unknown front matter #{unknown.join(', ')}; " \
                                                    "put links and other details in More Information")
    end

    status = metadata["status"]
    superseded = ADR_SUPERSEDED.match(status.to_s)
    if status.nil?
      problems << Problem.new(path: where, message: "front matter needs a status")
    elsif !ADR_STATUSES.include?(status) && !superseded
      problems << Problem.new(path: where, message: "status #{status.inspect} must be one of " \
                                                    "#{ADR_STATUSES.join(', ')}, or \"superseded by ADR-NNNN\"")
    elsif superseded && !numbers.include?(superseded[:number])
      problems << Problem.new(path: where, message: "superseded by ADR-#{superseded[:number]}, which does not exist")
    end

    date = metadata["date"]
    unless date.is_a?(Date) || ISO_DATE.match?(date.to_s)
      problems << Problem.new(path: where, message: "front matter needs a date in YYYY-MM-DD form")
    end

    if status != "proposed" && blank?(metadata["decision-makers"])
      problems << Problem.new(path: where,
                              message: "decision-makers are required once an ADR is #{status || 'decided'}")
    end
    problems
  end

  def check_adr_body(where, body)
    problems = []
    title = body.lines.map(&:chomp).find { |line| line.start_with?("# ") }
    if title.nil?
      problems << Problem.new(path: where, message: "missing a # title")
    elsif title.match?(/\A#\s+(?:ADR[- ]?)?\d+[.:]?\s/i)
      problems << Problem.new(path: where, message: "the title should state the decision without a number; " \
                                                    "the number is in the file name")
    end
    missing_sections(body, ADR_SECTIONS).each do |section|
      problems << Problem.new(path: where, message: "missing the ## #{section} section")
    end
    problems
  end

  def check_cir(root, path, number, numbers)
    where = relative(root, path)
    text = path.read(encoding: Encoding::UTF_8)
    problems = []

    title = text.lines.map(&:chomp).find { |line| line.start_with?("# ") }
    match = title && CIR_TITLE.match(title)
    if match.nil?
      problems << Problem.new(path: where, message: "title must be \"# CIR-#{number}: <what the change does>\"")
    elsif match[:number] != number
      problems << Problem.new(path: where, message: "title says CIR-#{match[:number]} but the file is #{number}")
    end

    missing_sections(text, CIR_SECTIONS).each do |section|
      problems << Problem.new(path: where, message: "missing the ## #{section} section")
    end

    date_section = section_text(text, "Date")
    if date_section && !date_section.match?(/^\d{4}-\d{2}-\d{2}\s*$/)
      problems << Problem.new(path: where, message: "the Date section needs a date in YYYY-MM-DD form")
    end

    text.scan(CIR_SUPERSEDES).flatten.each do |superseded|
      next if numbers.include?(superseded)

      problems << Problem.new(path: where, message: "supersedes CIR-#{superseded}, which does not exist")
    end
    problems
  end

  # Where mkdocs.yml lists record pages one by one, every record must be listed. A nav that
  # collects them by glob, or that leaves them to a plugin, is not checked.
  def check_nav(root, mkdocs, dirs)
    config_path = root.join(mkdocs)
    return [] unless config_path.file?

    config = config_path.read(encoding: Encoding::UTF_8)
    docs_dir = config[/^docs_dir:\s*['"]?([^'"\s]+)/, 1] || "docs"
    docs_root = config_path.dirname.join(docs_dir)

    dirs.flat_map do |dir|
      directory = root.join(dir)
      next [] unless directory.directory?

      in_docs = directory.relative_path_from(docs_root).to_s
      next [] if in_docs.start_with?("..")

      records = directory.children.map { |path| path.basename.to_s }.grep(FILE_NAME).sort
      listed = records.select { |name| config.include?("#{in_docs}/#{name}") }
      next [] if listed.empty?

      (records - listed).map do |name|
        Problem.new(path: relative(root, directory.join(name)), message: "missing from the #{mkdocs} nav")
      end
    end
  end

  def split_front_matter(text)
    match = /\A---\r?\n(?<yaml>.*?)^---\s*$\r?\n?(?<body>.*)\z/m.match(text)
    match ? [match[:yaml], match[:body]] : [nil, text]
  end

  def missing_sections(text, sections)
    headings = text.lines.filter_map { |line| line[/\A###? (.+?)\s*\z/, 1]&.downcase }
    sections.reject { |section| headings.include?(section.downcase) }
  end

  def section_text(text, section)
    match = /^## #{Regexp.escape(section)}\s*$\r?\n(?<content>.*?)(?=^## |\z)/mi.match(text)
    match && match[:content]
  end

  def blank?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?) || value.to_s.strip.empty?
  end

  def relative(root, path)
    path.relative_path_from(root).to_s
  end
end
