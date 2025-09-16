require 'rubygems'
require 'bundler/setup'

require 'open-uri'
require 'icalendar'
require 'yaml'
require 'forwardable'
require 'to_regexp'
require 'json'

# Load core and plugins automatically.
# Ensure transformer registry is available before loading transformers that register themselves.
begin
  require_relative 'ical_proxy/transformer/registry'
rescue LoadError
  # registry may not exist yet in older trees – ignore
end

# Require all library files under lib/ical_proxy (except this file and registry already required above)
base_dir = File.expand_path(__dir__)
Dir[File.join(base_dir, 'ical_proxy/**/*.rb')].sort.each do |file|
  next if File.expand_path(file) == File.expand_path(__FILE__)
  # Skip if it's the registry (we loaded earlier)
  next if file.end_with?(File.join('transformer', 'registry.rb'))
  require file
end

# Also load any drop-in addons placed under lib/ical_proxy/addons/**
addons_dir = File.join(base_dir, 'ical_proxy', 'addons')
if Dir.exist?(addons_dir)
  Dir[File.join(addons_dir, '**/*.rb')].sort.each { |f| require f }
end

module IcalProxy
  def self.calendars
    config.map { |name, calendar_config| [name, CalendarBuilder.new(name, calendar_config).build] }.to_h
  end

  def self.config
    content = File.read(config_file_path, :encoding => 'UTF-8')
    content.gsub! /\${(ICAL_PROXY_[^}]+)}/ do
      ENV[$1]
    end
    YAML.safe_load(content)
  end

  def self.config_file_path
    File.expand_path('../config.yml', __dir__)
  end

end
