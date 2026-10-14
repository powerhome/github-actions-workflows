#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

require_relative "review_prompt"

# Writes the review prompt to AGENT_PROMPT_PATH, outside the workspace, which the pull
# request controls and the provider reads.
# Only written on an incremental review.
incremental_diff_path = ENV.fetch("PR_INCREMENTAL_DIFF_PATH")
incremental_diff = nil
if File.file?(incremental_diff_path)
  incremental_diff = File.read(incremental_diff_path, encoding: Encoding::UTF_8).scrub
end

prompt = ReviewPrompt.new(
  base: File.read(ENV.fetch("REVIEW_PROMPT_PATH"), encoding: Encoding::UTF_8),
  context: JSON.parse(File.read(ENV.fetch("REVIEW_CONTEXT_PATH"), encoding: Encoding::UTF_8)),
  # Tagged with the locale's encoding, US-ASCII when nothing sets LANG, and joining it to the
  # UTF-8 prompt would raise on the first byte above ASCII.
  additional_instructions: ENV.fetch("REVIEW_ADDITIONAL_INSTRUCTIONS", "").dup.force_encoding(Encoding::UTF_8).scrub,
  incremental_diff:,
  # Set only when the provider step gets a read-only token for gh.
  gh_read_access: ENV.fetch("GH_READ_ACCESS", "false") == "true"
)

File.write(ENV.fetch("AGENT_PROMPT_PATH"), prompt.to_s)
