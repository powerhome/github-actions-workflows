# frozen_string_literal: true

require_relative "spec_helper"

require "tmpdir"

require "pr_diff_splitter"

RSpec.describe PrDiffSplitter do
  def file_diff(path, added)
    body = (1..added).map { |i| "+line #{i}\n" }.join
    header = "diff --git a/#{path} b/#{path}\nnew file mode 100644\n--- /dev/null\n+++ b/#{path}\n"
    "#{header}@@ -0,0 +1,#{added} @@\n#{body}"
  end

  it "keeps whole files together up to the limit and starts a new chunk after it" do
    diff = file_diff("a.rb", 100) + file_diff("b.rb", 100) + file_diff("c.rb", 100)
    splitter = described_class.new(diff, max_lines: 250)

    expect(splitter.changed_files).to eq(3)
    expect(splitter.chunks.map { |chunk| chunk.map(&:path) }).to eq([%w[a.rb b.rb], %w[c.rb]])
  end

  it "loses no lines and reorders nothing" do
    diff = file_diff("a.rb", 120) + file_diff("b.rb", 30) + file_diff("c.rb", 500)
    splitter = described_class.new(diff, max_lines: 100)
    joined = splitter.chunks.flatten.flat_map(&:lines).select { |line| line.start_with?("+line") }

    expect(joined.size).to eq(650)
  end

  it "splits a file too big for one chunk at hunk boundaries and repeats its header" do
    hunks = (1..3).map { |i| "@@ -#{i * 100},2 +#{i * 100},2 @@\n-old\n+new\n" }.join
    diff = "diff --git a/big.rb b/big.rb\nindex 1..2 100644\n--- a/big.rb\n+++ b/big.rb\n#{hunks}"
    splitter = described_class.new(diff, max_lines: 8)

    expect(splitter.chunks.size).to eq(3)
    splitter.chunks.flatten.each do |unit|
      expect(unit.lines.first).to eq("diff --git a/big.rb b/big.rb\n")
      expect(unit.lines.size).to be <= 8
    end
  end

  it "splits one oversized hunk with correct line numbers on each piece" do
    diff = file_diff("new.rb", 25)
    splitter = described_class.new(diff, max_lines: 15)
    headers = splitter.chunks.flatten.flat_map(&:lines).grep(/\A@@ /)

    expect(headers).to eq(
      [
        "@@ -0,0 +1,10 @@ (hunk split across chunks)\n",
        "@@ -0,0 +11,10 @@ (hunk split across chunks)\n",
        "@@ -0,0 +21,5 @@ (hunk split across chunks)\n",
      ]
    )
  end

  it "respects the byte limit" do
    diff = file_diff("a.rb", 10) + file_diff("b.rb", 10)
    splitter = described_class.new(diff, max_lines: 1000, max_bytes: file_diff("a.rb", 10).bytesize + 10)

    expect(splitter.chunks.size).to eq(2)
  end

  it "keeps a diff with no hunks, such as a binary file" do
    diff = "diff --git a/logo.png b/logo.png\nBinary files differ\n"
    splitter = described_class.new(diff)

    expect(splitter.changed_files).to eq(1)
    expect(splitter.chunks.flatten.first.path).to eq("logo.png")
  end

  it "handles an empty diff" do
    splitter = described_class.new("")

    expect(splitter.changed_files).to eq(0)
    expect(splitter.chunks).to be_empty
  end

  describe "#write" do
    it "replaces the directory, writes numbered chunks, and indexes them" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "pr-chunks")
        Dir.mkdir(dir)
        File.write(File.join(dir, "stale.diff"), "old")
        splitter = described_class.new(file_diff("a.rb", 5) + file_diff("b.rb", 5), max_lines: 12)
        splitter.write(dir)

        expect(Dir.children(dir).sort).to eq(%w[001.diff 002.diff INDEX.md])
        index = File.read(File.join(dir, "INDEX.md"))
        expect(index).to include("2 chunk file(s) covering 2 changed file(s)", "`001.diff` (", "a.rb", "b.rb")
      end
    end

    it "replaces a symlink at the directory instead of writing through it" do
      Dir.mktmpdir do |root|
        elsewhere = File.join(root, "elsewhere")
        Dir.mkdir(elsewhere)
        dir = File.join(root, "pr-chunks")
        File.symlink(elsewhere, dir)
        described_class.new(file_diff("a.rb", 1)).write(dir)

        expect(File.symlink?(dir)).to be(false)
        expect(Dir.children(elsewhere)).to be_empty
      end
    end
  end
end
