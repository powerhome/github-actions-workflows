#!/usr/bin/env ruby
# Loads every spec into one process, so the inline bundle is resolved once instead of
# once per file. Individual spec files still run on their own via the same helper.

require_relative "spec_helper"

Dir[File.expand_path("**/*_spec.rb", __dir__)].sort.each { |spec| require spec }
