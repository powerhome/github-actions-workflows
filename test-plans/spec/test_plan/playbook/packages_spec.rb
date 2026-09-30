# frozen_string_literal: true

require_relative "../../spec_helper"
require "test_plan/playbook/packages"

RSpec.describe TestPlan::Playbook do
  describe ".alpha_build?" do
    it "recognises a Playbook alpha in either spelling" do
      expect(described_class.alpha_build?("playbook_ui", "18.0.0.pre.alpha.play2430fixglobalprops19574")).to be(true)
      expect(described_class.alpha_build?("playbook-ui", "18.0.0-alpha.play2430fixglobalprops19574")).to be(true)
    end

    it "does not treat a release candidate or release as an alpha" do
      expect(described_class.alpha_build?("playbook_ui", "18.1.0.pre.rc.1")).to be(false)
      expect(described_class.alpha_build?("playbook-ui", "18.0.0")).to be(false)
    end

    it "leaves other packages' alphas to ordinary version ordering" do
      expect(described_class.alpha_build?("playbook-icons", "0.0.1-alpha.44")).to be(false)
    end
  end
end
