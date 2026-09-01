require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "rspec/autorun"

# So a spec names the script it exercises rather than its path back out of spec/.
$LOAD_PATH.unshift(File.expand_path("../scripts", __dir__))
