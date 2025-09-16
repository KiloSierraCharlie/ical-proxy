require_relative './lib/ical_proxy'
require_relative './lib/ical_proxy/servers/puma_app'
require_relative './lib/ical_proxy/servers/api_app'

map '/api' do
  run IcalProxy::Servers::ApiApp.new
end

map '/' do
  run IcalProxy::Servers::PumaApp.new(IcalProxy.calendars)
end
