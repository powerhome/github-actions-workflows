#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

require_relative "review_prompt"

# Writes the review prompt to AGENT_PROMPT_PATH, outside the workspace, which the pull
# request controls and the provider reads.
prompt = ReviewPrompt.new(
  base: File.read(ENV.fetch("REVIEW_PROMPT_PATH"), encoding: Encoding::UTF_8),
  context: JSON.parse(File.read(ENV.fetch("REVIEW_CONTEXT_PATH"), encoding: Encoding::UTF_8)),
  # Tagged with the locale's encoding, US-ASCII when nothing sets LANG, and joining it to the
  # UTF-8 prompt would raise on the first byte above ASCII.
  additional_instructions: ENV.fetch("REVIEW_ADDITIONAL_INSTRUCTIONS", "").dup.force_encoding(Encoding::UTF_8).scrub
)

File.write(ENV.fetch("AGENT_PROMPT_PATH"), prompt.to_s)
