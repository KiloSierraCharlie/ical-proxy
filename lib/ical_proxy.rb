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
    calendar_configs.map { |name, calendar_config| [name, CalendarBuilder.new(name, calendar_config).build] }.to_h
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

  def self.calendar_configs
    yaml_cfg = config
    yaml_cals = if yaml_cfg.is_a?(Hash) && yaml_cfg['calendars'].is_a?(Hash)
                  yaml_cfg['calendars']
                else
                  reserved = %w[storage]
                  yaml_cfg.select { |k, _| !reserved.include?(k.to_s) }
                end

    # Load DB calendars and merge underneath YAML (YAML wins)
    db_cals = db_calendar_configs
    merged = db_cals.merge(yaml_cals) # keys in yaml_cals override db
    merged
  end

  # Determine storage URI from env or config
  def self.storage_uri
    env = ENV['ICAL_PROXY_STORAGE']
    return env if env && !env.to_s.strip.empty?

    cfg = config
    val = cfg.is_a?(Hash) ? cfg['storage'] : nil
    return val if val && !val.to_s.strip.empty?

    # default to JSON in project root
    "json://#{File.expand_path('..', __dir__)}"
  end

  def self.storage_adapter
    @storage_adapter ||= IcalProxy::Storage::Factory.build(storage_uri)
  end

  def self.db_calendar_configs
    adapter = storage_adapter
    if adapter.respond_to?(:load_all_calendar_configs)
      adapter.load_all_calendar_configs
    else
      {}
    end
  end
end
