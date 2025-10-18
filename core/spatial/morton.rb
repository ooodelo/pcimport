# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Spatial
      # Morton/Z-order curve helpers.
      module Morton
        module_function

        def encode(x, y, z)
          interleave(x) | (interleave(y) << 1) | (interleave(z) << 2)
        end

        def interleave(value)
          value &= 0x1fffff
          value = (value | (value << 32)) & 0x1f00000000ffff
          value = (value | (value << 16)) & 0x1f0000ff0000ff
          value = (value | (value << 8)) & 0x100f00f00f00f00f
          value = (value | (value << 4)) & 0x10c30c30c30c30c3
          (value | (value << 2)) & 0x1249249249249249
        end
      end
    end
  end
end
