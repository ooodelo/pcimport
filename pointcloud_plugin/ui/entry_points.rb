# frozen_string_literal: true

module PointCloudPlugin
  module UI
    module EntryPoints
      extend self

      def setup
        return if loaded?

        PointCloudPlugin.log('Initializing UI entry points')
        PointCloudPlugin.setup_menu
        PointCloudPlugin.setup_toolbar
        mark_loaded
      rescue StandardError => e
        PointCloudPlugin.log("[UI::EntryPoints] Failed during setup: #{e.class}: #{e.message}")
        PointCloudPlugin.log(e.backtrace.join("\n")) if e.backtrace
        raise
      end

      private

      def loaded?
        defined?(@loaded) && @loaded
      end

      def mark_loaded
        @loaded = true
      end
    end
  end
end
