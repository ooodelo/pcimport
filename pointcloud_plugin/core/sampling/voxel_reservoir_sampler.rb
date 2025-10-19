# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Sampling
      # Downsamples point clouds by keeping at most one representative point per voxel
      # and adaptively merging voxels in dense areas. A light-weight secondary sampling
      # pass marks ~1% of the retained samples as anchors.
      class VoxelReservoirSampler
        Sample = Struct.new(:position, :color, :intensity, :anchor, keyword_init: true)

        GROWTH_FACTOR = 2.0
        DEFAULT_DENSITY_THRESHOLD = 64
        DEFAULT_MAX_LEVEL = 8
        DEFAULT_MIN_VOXEL_SIZE = 1.0e-6

        attr_reader :target_count, :anchor_ratio

        def initialize(target_count:, anchor_ratio: 0.01, density_threshold: DEFAULT_DENSITY_THRESHOLD,
                       max_level: DEFAULT_MAX_LEVEL, random: nil)
          @target_count = [target_count.to_i, 1].max
          @anchor_ratio = anchor_ratio.to_f.positive? ? anchor_ratio.to_f : 0.0
          @density_threshold = [density_threshold.to_i, 1].max
          @max_level = [max_level.to_i, 0].max
          @rng = random || Random.new

          reset_state
        end

        def reset_state
          @voxels = {}
          @min_bounds = [Float::INFINITY, Float::INFINITY, Float::INFINITY]
          @max_bounds = [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
          @voxel_size = nil
          @samples_cache = nil
          @voxel_size_estimated = false
        end

        def add(point)
          position = extract_position(point)
          return unless position

          update_bounds(position)
          ensure_voxel_size!

          key, voxel = locate_voxel(position)
          voxel ||= create_voxel(key)
          voxel[:seen] += 1
          voxel[:representative_position] = position

          accept_sample = voxel[:sample].nil? || replace_sample?(voxel[:seen])
          assign_sample(voxel, point, position) if accept_sample

          rebalance(voxel, position)
          @samples_cache = nil
        end

        def add_batch(points)
          Array(points).each { |point| add(point) }
        end

        def samples
          return @samples_cache if @samples_cache

          ordered_voxels = @voxels.values.select { |voxel| voxel[:sample] }
          ordered_voxels.sort_by! { |voxel| voxel[:key] }

          @samples_cache = ordered_voxels.map do |voxel|
            sample = voxel[:sample]
            Sample.new(
              position: sample[:position].dup,
              color: sample[:color] ? sample[:color].dup : nil,
              intensity: sample[:intensity],
              anchor: voxel[:anchor] ? true : false
            )
          end
        end

        def anchor_indices
          samples.each_with_index.filter_map do |sample, index|
            index if sample.anchor
          end
        end

        def voxel_size
          @voxel_size
        end

        private

        attr_reader :density_threshold, :max_level, :rng

        def extract_position(point)
          return unless point.is_a?(Hash)

          position = point[:position] || point['position']
          return unless position

          coords = Array(position).first(3)
          return unless coords.length == 3

          coords.map! { |value| value.to_f }
          coords
        rescue StandardError
          nil
        end

        def update_bounds(position)
          3.times do |axis|
            value = position[axis]
            @min_bounds[axis] = value if value < @min_bounds[axis]
            @max_bounds[axis] = value if value > @max_bounds[axis]
          end
        end

        def ensure_voxel_size!
          return if @voxel_size && @voxel_size_estimated

          volume = bounding_volume
          if volume <= 0.0
            @voxel_size = DEFAULT_MIN_VOXEL_SIZE
            @voxel_size_estimated = false
            return
          end

          size = (volume / target_count.to_f)**(1.0 / 3.0)
          size = DEFAULT_MIN_VOXEL_SIZE unless size.finite? && size.positive?
          @voxel_size = [size, DEFAULT_MIN_VOXEL_SIZE].max
          @voxel_size_estimated = true
        rescue StandardError
          @voxel_size ||= DEFAULT_MIN_VOXEL_SIZE
          @voxel_size_estimated = false unless @voxel_size_estimated
        end

        def bounding_volume
          extents = 3.times.map do |axis|
            delta = @max_bounds[axis] - @min_bounds[axis]
            delta.positive? ? delta : 0.0
          end
          extents.inject(1.0) { |memo, value| memo * value.to_f }
        end

        def locate_voxel(position)
          ensure_voxel_size!
          return [nil, nil] unless @voxel_size

          max_level.downto(0) do |level|
            key = voxel_key(position, level)
            voxel = @voxels[key]
            return [key, voxel] if voxel
          end

          key = voxel_key(position, 0)
          [key, @voxels[key]]
        end

        def create_voxel(key)
          voxel = {
            key: key,
            level: key.first,
            seen: 0,
            sample: nil,
            anchor: false,
            representative_position: nil
          }
          @voxels[key] = voxel
        end

        def replace_sample?(seen)
          return false unless seen && seen.positive?

          rng.rand < (1.0 / seen.to_f)
        end

        def assign_sample(voxel, point, position)
          sample = {
            position: position ? position.dup : extract_position(point),
            color: extract_color(point),
            intensity: point[:intensity] || point['intensity']
          }
          voxel[:sample] = sample
          voxel[:representative_position] = sample[:position] if sample[:position]
          voxel[:anchor] = rng.rand < anchor_ratio
        end

        def extract_color(point)
          color = point[:color] || point['color']
          return unless color

          values = Array(color).first(3)
          return unless values.any?

          values.map do |component|
            next 0 unless component

            begin
              Integer(component)
            rescue ArgumentError, TypeError
              begin
                Float(component).round
              rescue ArgumentError, TypeError
                0
              end
            end
          end
        rescue StandardError
          nil
        end

        def rebalance(voxel, position)
          loop do
            break unless should_grow?(voxel)

            grown = grow_voxel(voxel, position)
            break unless grown

            voxel = grown
            position = voxel[:representative_position] || position
          end
        end

        def should_grow?(voxel)
          return false unless voxel
          return false if voxel[:seen] <= capacity_for_level(voxel[:level])

          voxel[:level] < max_level
        end

        def capacity_for_level(level)
          density_threshold * (GROWTH_FACTOR**(level * 3))
        end

        def grow_voxel(voxel, position)
          return voxel unless voxel

          old_key = voxel[:key]
          new_level = [voxel[:level] + 1, max_level].min
          new_key = voxel_key(position || voxel[:representative_position], new_level)
          return voxel if new_key == old_key

          @voxels.delete(old_key)

          voxel[:key] = new_key
          voxel[:level] = new_level

          if (existing = @voxels[new_key])
            merge_voxels(existing, voxel)
            existing
          else
            @voxels[new_key] = voxel
            voxel
          end
        end

        def merge_voxels(parent, child)
          parent[:seen] += child[:seen]

          if child[:sample]
            if parent[:sample].nil?
              parent[:sample] = child[:sample]
              parent[:anchor] = child[:anchor]
              parent[:representative_position] = child[:representative_position]
            else
              replacement_probability = child[:seen].to_f / parent[:seen].to_f
              if rng.rand < replacement_probability
                parent[:sample] = child[:sample]
                parent[:anchor] = child[:anchor]
                parent[:representative_position] = child[:representative_position]
              end
            end
          end
        end

        def voxel_key(position, level)
          size = voxel_size_for_level(level)
          coords = Array(position || [0.0, 0.0, 0.0]).map(&:to_f)
          indices = coords.map do |value|
            (value / size).floor
          end
          ([level] + indices).freeze
        end

        def voxel_size_for_level(level)
          ensure_voxel_size!
          (@voxel_size || DEFAULT_MIN_VOXEL_SIZE) * (GROWTH_FACTOR**level)
        end
      end
    end
  end
end
