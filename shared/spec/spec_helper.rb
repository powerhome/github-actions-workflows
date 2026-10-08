# frozen_string_literal: true

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "rspec/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

SHARED_ROOT = File.expand_path("..", __dir__)

# System directories only, for running a provider script. Inheriting the caller's PATH
# meant a real CLI on this machine was found by `command -v`, skipping the install branch
# and running the actual agent against a scratch workspace.
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin".freeze
