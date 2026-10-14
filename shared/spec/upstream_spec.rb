# frozen_string_literal: true

require_relative "spec_helper"

require "json"
require "open3"

require "upstream"

RSpec.describe Upstream do
  # Records each request and answers with the next canned response.
  let(:requests) { [] }
  let(:responses) { [] }
  let(:http) do
    lambda do |uri, raw:|
      requests << [uri.to_s, raw]
      responses.shift || [200, "{}", "application/json"]
    end
  end

  subject(:upstream) { described_class.new(token: "ghs_job", api_url: "https://api.github.test", http:) }

  def respond(body, status: 200, type: "application/json")
    responses << [status, body.is_a?(String) ? body : JSON.dump(body), type]
  end

  describe "compare" do
    let(:comparison) do
      {
        "status" => "ahead", "ahead_by" => 2, "behind_by" => 0,
        "commits" => [
          { "sha" => "a" * 40, "commit" => { "message" => "Add an input\n\nLonger body" } },
          { "sha" => "b" * 40, "commit" => { "message" => "Fix the docs" } },
        ],
        "files" => [
          { "filename" => "action/action.yml", "status" => "modified", "additions" => 3, "deletions" => 1,
            "patch" => "@@ -1 +1 @@\n-old\n+new", },
          { "filename" => "other/README.md", "status" => "modified", "additions" => 1, "deletions" => 0 },
        ],
      }
    end

    it "lists the commits and changes between two refs" do
      respond(comparison)

      text = upstream.run(%w[compare acme/actions v1.2.0 feature/next])

      expect(requests).to eq([["https://api.github.test/repos/acme/actions/compare/v1.2.0...feature%2Fnext?per_page=100",
                               false]])
      expect(text).to include("acme/actions v1.2.0...feature/next: ahead, 2 commit(s) ahead, 0 behind")
      expect(text).to include("aaaaaaaaaaaa Add an input", "bbbbbbbbbbbb Fix the docs")
      expect(text).not_to include("Longer body")
      expect(text).to include("--- action/action.yml (modified, +3 -1)\n@@ -1 +1 @@\n-old\n+new")
      expect(text).to include("--- other/README.md (modified, +1 -0)\n(no patch: binary or too large)")
    end

    it "keeps only the files under a path" do
      respond(comparison)

      text = upstream.run(%w[compare acme/actions v1 v2 action])

      expect(text).to include("Files under action (1):", "action/action.yml")
      expect(text).not_to include("other/README.md")
    end
  end

  describe "show" do
    it "returns a file as it is at a ref, even a JSON one" do
      respond('{"name": "pkg"}', type: "application/vnd.github.raw+json; charset=utf-8")

      expect(upstream.run(["show", "acme/gem", "abc123", "lib/my gem.rb"])).to eq('{"name": "pkg"}')
      expect(requests).to eq([["https://api.github.test/repos/acme/gem/contents/lib/my%20gem.rb?ref=abc123", true]])
    end

    it "points a directory at ls" do
      respond([{ "type" => "file", "path" => "lib/a.rb" }])

      expect { upstream.run(%w[show acme/gem main lib]) }.to raise_error(Upstream::UsageError, /upstream ls/)
    end
  end

  describe "ls" do
    it "lists a directory at a ref" do
      respond([{ "type" => "dir", "path" => "lib/x" }, { "type" => "file", "path" => "lib/a.rb" }])

      expect(upstream.run(%w[ls acme/gem v2 lib])).to eq("dir  lib/x\nfile lib/a.rb")
      expect(requests.first.first).to eq("https://api.github.test/repos/acme/gem/contents/lib?ref=v2")
    end

    it "lists the repository root without a path" do
      respond([])
      upstream.run(%w[ls acme/gem main])

      expect(requests.first.first).to eq("https://api.github.test/repos/acme/gem/contents/?ref=main")
    end
  end

  # Nothing an argument holds may add path segments, query parameters or another host.
  describe "argument checks" do
    [
      ["a repository with extra segments", %w[ls acme/gem/x main]],
      ["a repository named ..", %w[ls acme/.. main]],
      ["a host in place of a repository", %w[ls https://evil.test/x main]],
      ["a ref range", %w[compare acme/gem a..b main]],
      ["a ref that looks like a flag", %w[ls acme/gem -X]],
      ["a ref with a query", ["ls", "acme/gem", "main?x=1"]],
      ["a path that climbs out", %w[show acme/gem main ../../etc/passwd]],
      ["a path with an empty segment", %w[show acme/gem main lib//a.rb]],
      ["an unknown command", %w[delete acme/gem main]],
      ["too many arguments", %w[ls acme/gem main lib extra]],
    ].each do |label, args|
      it "refuses #{label} without a request" do
        expect { upstream.run(args) }.to raise_error(Upstream::UsageError)
        expect(requests).to be_empty
      end
    end
  end

  it "explains a 404" do
    respond({ "message" => "Not Found" }, status: 404)

    expect { upstream.run(%w[ls acme/private main]) }.to raise_error(Upstream::RequestError, /not readable/)
  end

  it "cuts long output and says how to narrow it" do
    respond("x" * (Upstream::MAX_OUTPUT + 10), type: "application/vnd.github.raw+json")

    text = upstream.run(%w[show acme/gem main big.txt])

    expect(text.bytesize).to be < Upstream::MAX_OUTPUT + 200
    expect(text).to end_with("Narrow it with a PATH, or read single files with show.]")
  end

  it "only sends GET requests, with the token" do
    request = nil
    allow(Net::HTTP).to receive(:start) do |*_args, **_opts, &block|
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) do |req|
        request = req
        instance_double(Net::HTTPOK, code: "200", body: "[]").tap do |response|
          allow(response).to receive(:[]).with("content-type").and_return("application/json")
        end
      end
      block.call(http)
    end

    described_class.new(token: "ghs_job").run(%w[ls acme/gem main])

    expect(request).to be_a(Net::HTTP::Get)
    expect(request["Authorization"]).to eq("Bearer ghs_job")
    expect(request.uri.host).to eq("api.github.com")
  end

  it "runs as a command, reporting a refused argument on stderr" do
    bin = File.join(SHARED_ROOT, "agent-bin", "upstream")
    _stdout, stderr, status = Open3.capture3(bin, "show", "acme/gem", "main", "../secret")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("upstream: not a repository path")
  end
end
