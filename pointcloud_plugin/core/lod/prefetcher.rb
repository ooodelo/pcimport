# frozen_string_literal: true

require_relative '../spatial/index_builder'
require_relative '../spatial/frustum'

module PointCloudPlugin
  module Core
    module Lod
      # Determines which chunks should be prefetched based on view parameters.
      class Prefetcher
        HISTORY_LIMIT = 5
        PREDICTION_HORIZON = 0.5
        MIN_MOVEMENT_LENGTH = 1e-3

        def initialize(chunk_store, index_builder: nil)
          @chunk_store = chunk_store
          @index_builder = index_builder || Spatial::IndexBuilder.new(chunk_store)
          @camera_history = []
          @known_chunks = {}
          @index_dirty = true
        end

        def prefetch_for_view(
          frustum,
          budget: 8,
          camera_position: nil,
          camera_direction: nil,
          view: nil,
          timestamp: nil
        )
          timestamp ||= current_time
          track_camera_movement(camera_position, timestamp) if camera_position

          predicted_position = predict_position(PREDICTION_HORIZON)
          last_position = @camera_history.last&.fetch(:position, nil)
          movement_vector =
            if predicted_position && last_position
              predicted_position.zip(last_position).map { |predicted, current| predicted - current }
            end

          frustum = extend_frustum(frustum, movement_vector)

          camera_forward = normalized_vector(camera_direction) || normalized_vector(movement_vector)
          camera_reference_position = camera_position || predicted_position || last_position

          root = ensure_index_up_to_date
          return unless root

          nodes = if frustum
                    visible = @index_builder.visible_nodes(frustum)
                    visible.empty? ? root.visible_nodes(nil) : visible
                  else
                    root.visible_nodes(nil)
                  end

          keys = prioritized_chunk_keys(
            nodes,
            budget,
            camera_forward,
            camera_reference_position,
            view
          )

          @chunk_store.prefetch(keys) if keys.any?
        end

        private

        VISIBILITY_MARGIN = 0.1

        def track_camera_movement(position, timestamp)
          entry = { position: position.map(&:to_f), timestamp: timestamp.to_f }
          @camera_history << entry
          @camera_history.shift while @camera_history.length > HISTORY_LIMIT
        end

        def predict_position(horizon)
          return if @camera_history.length < 2

          velocities = @camera_history.each_cons(2).map do |previous, current|
            delta_time = current[:timestamp] - previous[:timestamp]
            next unless delta_time.positive?

            displacement = current[:position].zip(previous[:position]).map do |current_component, previous_component|
              current_component - previous_component
            end
            displacement.map { |component| component / delta_time }
          end.compact

          return if velocities.empty?

          averaged_velocity = velocities.transpose.map do |components|
            components.sum / components.length.to_f
          end

          last_position = @camera_history.last[:position]
          last_position.zip(averaged_velocity).map do |position_component, velocity_component|
            position_component + velocity_component * horizon
          end
        end

        def extend_frustum(frustum, movement_vector)
          return frustum unless significant_movement?(movement_vector)

          extended_planes = frustum.planes.map do |plane|
            normal = plane.normal
            offset = dot_product(normal, movement_vector)
            distance_adjustment = offset.positive? ? offset : 0.0
            Spatial::Plane.new(normal.dup, plane.distance - distance_adjustment)
          end

          Spatial::Frustum.new(extended_planes, epsilon: frustum.epsilon)
        end

        def significant_movement?(movement_vector)
          return false unless movement_vector

          movement_vector.any? { |component| component.abs > MIN_MOVEMENT_LENGTH }
        end

        def dot_product(a, b)
          a.zip(b).sum { |av, bv| av * bv }
        end

        def current_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        rescue StandardError
          Time.now.to_f
        end

        def ensure_index_up_to_date
          entries = current_entries

          removed_keys = @known_chunks.keys - entries.keys
          replaced_keys = entries.select { |key, chunk| @known_chunks.key?(key) && @known_chunks[key] != chunk.object_id }.keys
          new_keys = entries.keys - @known_chunks.keys

          if @index_dirty || removed_keys.any? || replaced_keys.any?
            root = @index_builder.build
            @known_chunks = entries.transform_values(&:object_id)
            @index_dirty = false
            return root
          end

          new_keys.each do |key|
            chunk = entries[key]
            next unless chunk

            @index_builder.add_chunk(key, chunk)
            @known_chunks[key] = chunk.object_id
          end

          @index_builder.root
        end

        def prioritized_chunk_keys(nodes, budget, camera_forward, camera_position, view)
          candidates = nodes.flat_map do |node|
            node.chunk_refs.map do |reference|
              build_prefetch_candidate(reference, camera_forward, camera_position, view)
            end
          end.compact

          ordered_keys = candidates
            .sort_by do |candidate|
              [
                candidate[:near_visible] ? 0 : 1,
                -candidate[:cosine],
                candidate[:distance]
              ]
            end
            .map { |candidate| candidate[:key] }
            .uniq

          return [] if budget && budget <= 0
          return ordered_keys unless budget && budget.positive?

          ordered_keys.first(budget)
        end

        def build_prefetch_candidate(reference, camera_forward, camera_position, view)
          key = reference[:key]
          bounds = reference[:bounds]

          distance_vector = vector_to_bounds(bounds, camera_position)
          distance = vector_length(distance_vector)
          cosine = cosine_to_forward(camera_forward, distance_vector, distance)

          near_visible = near_visible_chunk?(bounds, view)

          {
            key: key,
            cosine: cosine,
            distance: distance || Float::INFINITY,
            near_visible: near_visible
          }
        end

        def vector_to_bounds(bounds, camera_position)
          return nil unless bounds && camera_position

          center = bounds_center(bounds)
          center.zip(camera_position).map { |component, origin| component - origin }
        end

        def bounds_center(bounds)
          mins = bounds[:min]
          maxs = bounds[:max]
          mins.each_with_index.map { |value, axis| (value + maxs[axis]) * 0.5 }
        end

        def cosine_to_forward(camera_forward, distance_vector, distance)
          return -1.0 unless camera_forward && distance_vector && distance && distance.positive?

          dot_product(camera_forward, distance_vector) / distance
        end

        def vector_length(vector)
          return nil unless vector

          Math.sqrt(vector.sum { |component| component * component })
        end

        def normalized_vector(vector)
          return unless vector

          length = vector_length(vector)
          return unless length && length.positive?

          vector.map { |component| component / length }
        end

        def near_visible_chunk?(bounds, view)
          return false unless bounds
          return false unless defined?(PointCloud::UI::Visibility)

          visibility = PointCloud::UI::Visibility
          return false unless visibility.respond_to?(:chunk_visible?)

          view ||= visibility.respond_to?(:current_view) ? visibility.current_view : nil
          return false unless view

          margin = visibility.respond_to?(:prefetch_margin) ? visibility.prefetch_margin : VISIBILITY_MARGIN

          begin
            visibility.chunk_visible?(view, bounds, margin: margin)
          rescue ArgumentError
            visibility.chunk_visible?(view, bounds)
          rescue StandardError
            false
          end
        end

        def current_entries
          @chunk_store.each_in_memory.each_with_object({}) do |(key, chunk), hash|
            hash[key] = chunk
          end
        end
      end
    end
  end
end
