module IcalProxy
  module Transformer
    # Example addon transformer: uppercases the event summary.
    class UppercaseSummary
      def initialize(enabled = true)
        @enabled = !!enabled
      end

      def apply(event)
        return unless @enabled
        event.summary = event.summary.to_s.upcase
      end
    end
  end
end

# Register under transformations.uppercase_summary: true|false
begin
  IcalProxy::Transformer::Registry.register('uppercase_summary') do |enabled|
    if enabled
      IcalProxy::Transformer::UppercaseSummary.new(true)
    else
      nil
    end
  end
rescue NameError
  # registry not available yet
end

