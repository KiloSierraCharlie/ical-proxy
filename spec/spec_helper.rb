require 'rspec'
require 'rspec_junit_formatter'
require 'webmock/rspec'
begin
  require 'tzinfo/data'
rescue LoadError
end
require 'ical_proxy'

RSpec.configure do |config|
  # Use color in STDOUT
  config.color = true

  # Use the specified formatter
  config.formatter = :documentation
end

WebMock.disable_net_connect!(allow_localhost: true)
