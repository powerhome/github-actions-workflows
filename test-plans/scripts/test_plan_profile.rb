#!/usr/bin/env ruby

require "json"

class TestPlanProfile
  ID_PATTERN = /\A[a-z][a-z0-9-]*\z/
  REQUIRED_STRING_FIELDS = %w[
    id
    display_name
    prompt
    model
    comment_tag
    status_comment_tag
    failure_comment_tag
    artifact_name
  ].freeze

  attr_reader :attributes, :action_root

  def self.load(action_root:, profile_id:)
    unless ID_PATTERN.match?(profile_id.to_s)
      raise "Invalid test-plan profile: #{profile_id.inspect}"
    end

    profiles_root = File.join(action_root, "profiles")
    path = File.join(profiles_root, "#{profile_id}.json")
    raise "Unknown test-plan profile: #{profile_id}" unless File.file?(path)

    new(
      action_root: action_root,
      attributes: JSON.parse(File.read(path, encoding: Encoding::UTF_8))
    ).tap(&:validate!)
  end

  def initialize(action_root:, attributes:)
    @action_root = File.expand_path(action_root)
    @attributes = attributes
  end

  def validate!
    raise "Test-plan profile must be a JSON object" unless attributes.is_a?(Hash)

    REQUIRED_STRING_FIELDS.each do |field|
      value = attributes[field]
      raise "Test-plan profile #{field} must be a string" unless value.is_a?(String)
    end

    unless ID_PATTERN.match?(attributes.fetch("id"))
      raise "Test-plan profile id is invalid: #{attributes.fetch("id").inspect}"
    end

    prompt_path
    self
  end

  def id
    attributes.fetch("id")
  end

  def display_name
    attributes.fetch("display_name")
  end

  def model
    attributes.fetch("model")
  end

  def comment_tag
    attributes.fetch("comment_tag")
  end

  def status_comment_tag
    attributes.fetch("status_comment_tag")
  end

  def failure_comment_tag
    attributes.fetch("failure_comment_tag")
  end

  def artifact_name
    attributes.fetch("artifact_name")
  end

  def prompt_path
    candidate = File.expand_path(attributes.fetch("prompt"), action_root)
    action_prefix = "#{action_root}#{File::SEPARATOR}"
    unless candidate.start_with?(action_prefix) && File.file?(candidate)
      raise "Test-plan profile prompt is invalid: #{attributes.fetch("prompt").inspect}"
    end

    candidate
  end

  def to_h
    {
      "profile_id" => id,
      "display_name" => display_name,
      "model" => model,
      "comment_tag" => comment_tag,
      "status_comment_tag" => status_comment_tag,
      "failure_comment_tag" => failure_comment_tag,
      "artifact_name" => artifact_name,
      "prompt_path" => prompt_path,
    }
  end
end
