#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# The REST and GraphQL calls the review scripts make, over Net::HTTP so the action needs
# nothing beyond the runner's preinstalled Ruby.
class GitHubApi
  class RequestError < StandardError; end

  # MAX_PAGES only stops the loop if the API keeps answering with full pages.
  PER_PAGE = 100
  MAX_PAGES = 20

  def initialize(token:)
    @token = token
  end

  def get(path)
    request(Net::HTTP::Get.new(rest_uri(path)))
  end

  def post(path, payload)
    request(Net::HTTP::Post.new(rest_uri(path)), payload)
  end

  # Every page of a REST list endpoint, in the order the API returns them.
  def get_all(path)
    separator = path.include?("?") ? "&" : "?"
    items = []

    1.upto(MAX_PAGES) do |page|
      batch = get("#{path}#{separator}per_page=#{PER_PAGE}&page=#{page}")
      batch = [] unless batch.is_a?(Array)
      items.concat(batch)
      break if batch.length < PER_PAGE
    end

    items
  end

  # GraphQL answers 200 with an "errors" array when a query or mutation fails, so those
  # are raised the same as an HTTP error.
  def graphql(query, variables = {})
    uri = URI(ENV.fetch("GITHUB_GRAPHQL_URL", "https://api.github.com/graphql"))
    payload = request(Net::HTTP::Post.new(uri), { query:, variables: })
    errors = payload.is_a?(Hash) ? Array(payload["errors"]) : []
    raise RequestError, "GraphQL: #{errors.map { |e| e["message"] }.join(' | ')}" if errors.any?

    payload.fetch("data")
  end

private

  def rest_uri(path)
    base = ENV.fetch("GITHUB_API_URL", "https://api.github.com").chomp("/")
    URI("#{base}/") + path.delete_prefix("/")
  end

  def request(request, payload = nil)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = "nitro-agentic-pr-review"
    if payload
      request.content_type = "application/json"
      request.body = JSON.dump(payload)
    end

    uri = request.uri
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end

    return parse_response(response) if response.is_a?(Net::HTTPSuccess)

    raise RequestError, format_error(response)
  end

  def parse_response(response)
    return if response.body.to_s.empty?

    JSON.parse(response.body)
  rescue JSON::ParserError
    response.body
  end

  def format_error(response)
    payload = parse_response(response)
    message =
      if payload.is_a?(Hash)
        details = Array(payload["errors"]).map(&:inspect)
        [payload["message"], *details].compact.join(" | ")
      else
        payload.to_s
      end

    "HTTP #{response.code}: #{message}"
  end
end
