require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "rspec/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

ACTION_ROOT = File.expand_path("..", __dir__)
