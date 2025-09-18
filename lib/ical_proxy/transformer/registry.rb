module IcalProxy
  module Transformer
    # Simple plugin registry for building transformers from config.
    #
    # Transformer files can call:
    #   IcalProxy::Transformer::Registry.register('key') { |section| ... }
    # The block should return a transformer instance or an array of instances.
    class Registry
      @builders = {}

      class << self
        def register(key, &builder)
          @builders[key.to_s] = builder
        end

        # Build transformer instances from a transformations config hash.
        def build_from_config(cfg)
          return [] unless cfg.is_a?(Hash)
          instances = []
          @builders.each do |key, builder|
            section = cfg[key]
            next if section.nil?
            built = safe_call(builder, section)
            Array(built).compact.each { |t| instances << t }
          end
          instances
        end

        private

        def safe_call(builder, section)
          builder.call(section)
        rescue StandardError => e
          warn("[Transformer::Registry] Failed building '#{builder}': #{e.class}: #{e.message}")
          nil
        end
      end
    end
  end
end

