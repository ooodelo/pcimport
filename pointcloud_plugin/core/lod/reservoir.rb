# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Lod
      # Reservoir sampling to select representative points for preview.
      class Reservoir
        attr_reader :size, :samples

        def initialize(size)
          @size = size
          @samples = []
          @seen = 0
        end

        def offer(point)
          @seen += 1
          if samples.size < size
            samples << point
          else
            index = rand(@seen)
            samples[index] = point if index < size
          end
        end

        def reset!
          @samples.clear
          @seen = 0
        end
      end
    end
  end
end
