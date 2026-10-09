# frozen_string_literal: true

require_relative "../../spec_helper"
require "test_plan/dependency_delta/npm_lock_parser"

require "json"

RSpec.describe TestPlan::DependencyDelta::NpmLockParser do
  def records(packages)
    described_class.new(JSON.generate("lockfileVersion" => 3, "packages" => packages)).records
  end

  # Version 2 also carries the v1 dependencies tree, for older npm; only packages is read.
  it "reads a lockfileVersion 2 file through its packages map" do
    content = JSON.generate(
      "lockfileVersion" => 2,
      "packages" => { "node_modules/swiper" => { "version" => "14.0.7" } },
      "dependencies" => { "swiper" => { "version" => "10.0.4" } }
    )

    expect(described_class.new(content).records.map { |record| [record.name, record.version, record.path] })
      .to eq([["swiper", "14.0.7", "node_modules/swiper"]])
  end

  it "says a supported version is missing its packages map rather than calling it unsupported" do
    [2, 3].each do |version|
      content = JSON.generate("lockfileVersion" => version, "dependencies" => {})

      expect { described_class.new(content).records }
        .to raise_error('package-lock.json must include a "packages" object')
    end
  end

  it "names each installed package from its path, including scoped and nested installs" do
    packages = {
      "" => { "name" => "site", "dependencies" => { "alpinejs" => "3.9.6" } },
      "node_modules/alpinejs" => {
        "version" => "3.9.6",
        "resolved" => "https://registry.npmjs.org/alpinejs/-/alpinejs-3.9.6.tgz",
        "integrity" => "sha512-abc",
      },
      "node_modules/@alpinejs/focus" => { "version" => "3.12.3" },
      "node_modules/postcss/node_modules/nanoid" => { "version" => "3.3.7" },
    }
    parsed = records(packages)

    expect(parsed.map { |record| [record.name, record.version] }).to contain_exactly(
      ["alpinejs", "3.9.6"], ["@alpinejs/focus", "3.12.3"], ["nanoid", "3.3.7"]
    )
    alpine = parsed.find { |record| record.name == "alpinejs" }
    expect(alpine.resolved).to eq("https://registry.npmjs.org/alpinejs/-/alpinejs-3.9.6.tgz")
    expect(alpine.integrity).to eq("sha512-abc")
  end

  # An alias installs under the name the manifest asked for; evidence belongs to the
  # package actually installed.
  it "fetches an alias by the package it installed" do
    parsed = records("node_modules/legacy-widget" => { "name" => "widget", "version" => "2.0.0" })

    expect(parsed.first.name).to eq("widget")
    expect(parsed.first.alias).to eq("legacy-widget")
  end

  it "skips workspace members and the links that point to them" do
    packages = {
      "packages/theme" => { "name" => "theme", "version" => "1.0.0" },
      "node_modules/theme" => { "resolved" => "packages/theme", "link" => true },
      "packages/theme/node_modules/swiper" => { "version" => "14.0.7" },
      "packages/theme/node_modules/@alpinejs/focus" => { "version" => "3.12.3" },
    }

    expect(records(packages).map(&:name)).to contain_exactly("swiper", "@alpinejs/focus")
  end

  it "does not read a workspace member as an install because node_modules is in its name" do
    packages = {
      "packages/custom_node_modules/widget" => { "name" => "widget", "version" => "1.0.0" },
      "node_modules/widget" => { "resolved" => "packages/custom_node_modules/widget", "link" => true },
      "packages/custom_node_modules/widget/node_modules/swiper" => { "version" => "14.0.7" },
    }

    expect(records(packages).map(&:name)).to eq(["swiper"])
  end

  it "keeps a Git resolution so the detector can read its revision" do
    resolved = "git+ssh://git@github.com/example/forked.git#abc1234"
    parsed = records("node_modules/forked" => { "version" => "1.0.0", "resolved" => resolved })

    expect(parsed.first.resolved).to eq(resolved)
  end

  it "refuses a lockfileVersion 1 file rather than reading it as empty" do
    content = JSON.generate("lockfileVersion" => 1, "dependencies" => { "a" => { "version" => "1.0.0" } })

    expect { described_class.new(content).records }
      .to raise_error(/lockfileVersion 1 is not supported/)
  end

  it "refuses a version it does not know even when it has a packages map" do
    ["1", 1, 4, nil].each do |version|
      content = JSON.generate(
        "lockfileVersion" => version,
        "packages" => { "node_modules/a" => { "version" => "1.0.0" } }
      )

      expect { described_class.new(content).records }
        .to raise_error(/lockfileVersion #{Regexp.escape(version.inspect)} is not supported/)
    end
  end
end
