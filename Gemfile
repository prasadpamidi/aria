# frozen_string_literal: true

source "https://rubygems.org"

# No `ruby` directive: lets CI runners and rbenv setups each use whatever
# modern Ruby is on the path.

# Fastlane for build automation and code-quality lanes
gem "fastlane"

# Plugins (loaded from Pluginfile if it exists)
plugins_path = File.join(File.dirname(__FILE__), "fastlane", "Pluginfile")
eval_gemfile(plugins_path) if File.exist?(plugins_path)
