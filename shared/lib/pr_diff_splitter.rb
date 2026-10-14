# frozen_string_literal: true

require "fileutils"

# Splits a unified diff into chunks small enough for a reviewer to read whole. A single
# read of a large pr.diff comes back truncated, and a model that is not told otherwise
# reviews what it was given and stops. Chunks break at file boundaries, then at hunk
# boundaries, and only inside a hunk when that hunk alone is too big, where each piece gets
# a hunk header with the right line numbers so comments can still be anchored.
class PrDiffSplitter
  Unit = Struct.new(:lines, :path)

  def initialize(diff, max_lines: 400, max_bytes: 32_000)
    @lines = diff.lines
    @max_lines = max_lines
    @max_bytes = max_bytes
  end

  def changed_files
    sections.size
  end

  def chunks
    @chunks ||= pack(
      sections.flat_map { |path, lines| fits?(lines) ? [Unit.new(lines, path)] : split_section(path, lines) }
    )
  end

  def index_markdown
    listing = chunks.each_with_index.map do |chunk, i|
      "- `#{chunk_name(i)}` (#{chunk.sum { |unit| unit.lines.size }} lines): #{chunk.map(&:path).uniq.join(', ')}"
    end

    <<~MARKDOWN
      # PR diff chunks

      The diff for this pull request is split into #{chunks.size} chunk file(s) covering #{changed_files} changed file(s). Read every chunk before reviewing. A file's diff can continue across chunks.

      #{listing.join("\n")}
    MARKDOWN
  end

  def write(dir)
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    chunks.each_with_index do |chunk, i|
      File.write(File.join(dir, chunk_name(i)), chunk.flat_map(&:lines).join)
    end
    File.write(File.join(dir, "INDEX.md"), index_markdown)
  end

private

  def chunk_name(index)
    format("%03d.diff", index + 1)
  end

  def sections
    @sections ||= @lines.slice_before { |line| line.start_with?("diff --git ") }
                        .select { |lines| lines.first.start_with?("diff --git ") }
                        .map { |lines| [lines.first[/ b\/(.+)\s*\z/, 1] || lines.first.strip, lines] }
  end

  def fits?(lines)
    lines.size <= @max_lines && lines.sum(&:bytesize) <= @max_bytes
  end

  def pack(units)
    units.each_with_object([[]]) do |unit, chunks|
      chunks << [] if chunks.last.any? && !fits?((chunks.last + [unit]).flat_map(&:lines))
      chunks.last << unit
    end.reject(&:empty?)
  end

  def split_section(path, lines)
    header = lines.take_while { |line| !line.start_with?("@@ ") }
    hunks = lines.drop(header.size).slice_before { |line| line.start_with?("@@ ") }.to_a
    units = []
    current = header.dup

    hunks.each do |hunk|
      if fits?(header + hunk)
        if current.size > header.size && !fits?(current + hunk)
          units << Unit.new(current, path)
          current = header.dup
        end
        current += hunk
      else
        units << Unit.new(current, path) if current.size > header.size
        units.concat(split_hunk(path, header, hunk))
        current = header.dup
      end
    end

    units << Unit.new(current, path) if current.size > header.size || units.empty?
    units
  end

  def split_hunk(path, header, hunk)
    old_line, new_line = hunk.first.match(/\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/).captures.map(&:to_i)
    pieces = []
    body = []

    hunk.drop(1).each do |line|
      if body.any? && !fits?(header + [hunk.first] + body + [line])
        pieces << body
        body = []
      end
      body << line
    end
    pieces << body if body.any?

    pieces.map do |piece|
      old_count = piece.count { |line| !line.start_with?("+", "\\") }
      new_count = piece.count { |line| !line.start_with?("-", "\\") }
      hunk_header = "@@ -#{old_line},#{old_count} +#{new_line},#{new_count} @@ (hunk split across chunks)\n"
      old_line += old_count
      new_line += new_count
      Unit.new(header + [hunk_header] + piece, path)
    end
  end
end
