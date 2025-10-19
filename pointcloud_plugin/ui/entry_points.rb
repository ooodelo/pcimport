# frozen_string_literal: true

module PointCloudPlugin
  module UI
    module EntryPoints
      extend self

      def setup
        return if loaded?

        PointCloudPlugin.log('Initializing UI entry points')
        initialize_ui
        schedule_post_start_initialization
        mark_loaded
      rescue StandardError => e
        reset_loaded_flag
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

      def reset_loaded_flag
        remove_instance_variable(:@loaded) if defined?(@loaded)
      rescue NameError
        # no-op if the variable was not set
      end

      def initialize_ui
        PointCloudPlugin.setup_menu
        PointCloudPlugin.setup_toolbar
      end

      def schedule_post_start_initialization
        return unless defined?(::UI) && ::UI.respond_to?(:start_timer)

        ::UI.start_timer(0, false) do
          initialize_ui
        rescue StandardError => e
          reset_loaded_flag
          PointCloudPlugin.log("[UI::EntryPoints] Deferred setup failed: #{e.class}: #{e.message}")
          PointCloudPlugin.log(e.backtrace.join("\n")) if e.backtrace
          raise
        end
      end
    end
  end
end
