# frozen_string_literal: true

module PointCloudPlugin
  module UI
    # Placeholder renderer for future GPU-based overlays. Currently acts as a
    # no-op while the feature is in beta.
    class OverlayRenderer
      attr_writer :enabled

      def initialize
        @enabled = false
      end

      def enabled?
        !!@enabled
      end

      def draw(_view, _targets)
        return nil unless enabled?

        { handled: false }
      end
    end
  end
end
