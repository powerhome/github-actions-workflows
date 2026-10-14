#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "pr_diff_splitter"

diff_path = ENV.fetch("PR_DIFF_PATH")
chunks_dir = ENV.fetch("PR_CHUNKS_DIR")

splitter = PrDiffSplitter.new(File.read(diff_path, encoding: Encoding::UTF_8, invalid: :replace, undef: :replace))
splitter.write(chunks_dir)

warn "[split_pr_diff] #{splitter.changed_files} changed file(s) in #{splitter.chunks.size} chunk(s) at #{chunks_dir}"

if ENV["GITHUB_OUTPUT"]
  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |output|
    output.puts "changed_files=#{splitter.changed_files}"
    output.puts "chunk_count=#{splitter.chunks.size}"
  end
end
