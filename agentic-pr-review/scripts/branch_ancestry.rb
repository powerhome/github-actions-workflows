#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "github_api"

# Whether the last-reviewed commit is still in the branch's history, which decides between an
# incremental review and a full one.
#
# The checkout is shallow, reaching back only to the merge base, so git can't answer this
# itself: after a merge from the base branch the shallow boundary can cut the path back to the
# reviewed commit, and `git merge-base --is-ancestor` then fails for a branch nobody rewrote.
# The compare API sees the whole history. The commit is still fetched by SHA, because the
# incremental diff is taken against it.
class BranchAncestry
  # How compare describes a head that has the base in its history.
  DESCENDANT_STATUSES = %w[ahead identical].freeze

  def initialize(api:, owner:, repo:, git_dir: ".")
    @api = api
    @owner = owner
    @repo = repo
    @git_dir = git_dir
  end

  def ancestor?(sha, head_sha)
    fetch(sha) unless commit_present?(sha)
    return false unless commit_present?(sha)

    DESCENDANT_STATUSES.include?(compare_status(sha, head_sha))
  end

private

  # A 404 means GitHub no longer has the commit, which a force-push can lead to, so that
  # and any other failure fall back to a full review.
  def compare_status(sha, head_sha)
    @api.get("/repos/#{@owner}/#{@repo}/compare/#{sha}...#{head_sha}?per_page=1")&.fetch("status", nil)
  rescue GitHubApi::RequestError => e
    warn "[branch_ancestry] compare #{sha[0, 7]}...#{head_sha[0, 7]} failed: #{e.message}"
    nil
  end

  def commit_present?(sha)
    git("cat-file", "-e", "#{sha}^{commit}")
  end

  def fetch(sha)
    git("fetch", "--no-tags", "--quiet", "--depth=1", "origin", sha)
  end

  def git(*args)
    system("git", "-C", @git_dir, *args, out: File::NULL, err: File::NULL)
  end
end
