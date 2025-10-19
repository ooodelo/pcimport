# frozen_string_literal: true

require 'set'

require_relative '../spatial/index_builder'

module PointCloudPlugin
  module Core
    module Lod
      # Determines which chunks should be prefetched based on view parameters.
      class Prefetcher
        HISTORY_LIMIT = 5
        PREDICTION_HORIZON = 0.5
        DEFAULT_PREFETCH_LIMIT = 32
        DEFAULT_ANGLE_WEIGHT = 10.0
        DEFAULT_DISTANCE_WEIGHT = 1.0
        DEFAULT_FORWARD_COSINE_THRESHOLD = 0.0

        attr_reader :max_prefetch, :angle_weight, :distance_weight, :forward_cosine_threshold

        def initialize(chunk_store, index_builder: nil)
          @chunk_store = chunk_store
          @index_builder = index_builder || Spatial::IndexBuilder.new(chunk_store)
          @camera_history = []
          @known_chunks = {}
          @index_dirty = true
          @max_prefetch = DEFAULT_PREFETCH_LIMIT
          @angle_weight = DEFAULT_ANGLE_WEIGHT
          @distance_weight = DEFAULT_DISTANCE_WEIGHT
          @forward_cosine_threshold = DEFAULT_FORWARD_COSINE_THRESHOLD
        end

        def prefetch_for_view(
          visible_chunks,
          budget: 8,
          camera_position: nil,
          camera_direction: nil,
          view: nil,
          timestamp: nil,
          max_prefetch: nil
        )
          max_prefetch ||= @max_prefetch
          timestamp ||= current_time
          track_camera_movement(camera_position, timestamp) if camera_position

          predicted_position = predict_position(PREDICTION_HORIZON)
          last_position = @camera_history.last&.fetch(:position, nil)
          movement_vector =
            if predicted_position && last_position
              predicted_position.zip(last_position).map { |predicted, current| predicted - current }
            end

          camera_forward = normalized_vector(camera_direction) || normalized_vector(movement_vector)
          camera_reference_position = camera_position || predicted_position || last_position

          root = ensure_index_up_to_date
          return unless root

          loaded_entries = current_entries

          candidates = build_prefetch_candidates(
            root,
            visible_chunks,
            camera_forward,
            camera_reference_position,
            view
          )

          limit = effective_prefetch_limit(budget: budget, max_prefetch: max_prefetch)
          capacity = available_prefetch_capacity(loaded_entries.length)
          limit = [limit, capacity].compact.min
          return if limit && limit <= 0

          keys = ordered_prefetch_keys(candidates)
          keys.reject! { |key| loaded_entries.key?(key) }
          keys = keys.first(limit) if limit

          @chunk_store.prefetch(keys) if keys.any?
        end

        def configure(max_prefetch: nil, angle_weight: nil, distance_weight: nil, forward_threshold: nil)
          @max_prefetch = [max_prefetch.to_i, 0].max if max_prefetch
          @angle_weight = angle_weight.to_f if angle_weight
          @distance_weight = distance_weight.to_f if distance_weight
          if forward_threshold
            value = forward_threshold.to_f
            @forward_cosine_threshold = value.clamp(-1.0, 1.0)
          end
        end

        private

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

        def build_prefetch_candidates(root, visible_chunks, camera_forward, camera_position, view)
          normalized_visible = normalize_visible_chunks(visible_chunks, root, view)
          visible_keys = normalized_visible.map { |entry| entry[:key] }.compact.to_set

          references = collect_chunk_references(root)

          references.map do |reference|
            key = reference[:key]
            bounds = reference[:bounds]

            near_visible = visible_keys.include?(key)
            distance_vector = vector_to_bounds(bounds, camera_position)
            distance = vector_length(distance_vector)
            cosine = cosine_to_forward(camera_forward, distance_vector, distance)

            next if !near_visible && !include_candidate?(cosine, camera_forward, camera_position)

            distance_metric =
              if distance.nil?
                near_visible ? 0.0 : Float::INFINITY
              else
                distance
              end

            {
              key: key,
              bounds: bounds,
              distance: distance_metric,
              cosine: cosine,
              near_visible: near_visible,
              priority: priority_score(cosine, distance_metric, near_visible)
            }
          end.compact
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

        def current_entries
          @chunk_store.each_in_memory.each_with_object({}) do |(key, chunk), hash|
            hash[key] = chunk
          end
        end

        def collect_chunk_references(root)
          root.each_leaf.flat_map(&:chunk_refs)
        end

        def normalize_visible_chunks(visible_chunks, root, view)
          Array(visible_chunks).compact.map do |entry|
            extract_visible_chunk(entry, root, view)
          end.compact
        end

        def extract_visible_chunk(entry, root, view)
          if entry.is_a?(Hash)
            key = entry[:key] || entry['key']
            bounds = entry[:bounds] || entry['bounds']
            chunk = entry[:chunk] || entry['chunk']
          elsif entry.is_a?(Array)
            key, chunk = entry
            bounds = nil
          else
            key = entry
            bounds = nil
            chunk = nil
          end

          return if chunk && empty_chunk?(chunk)

          bounds ||= chunk_bounds(chunk)
          bounds ||= bounds_from_index(key, root)
          bounds ||= bounds_from_visibility(view, key)

          return unless key
          return unless bounds_valid?(bounds)

          { key: key, bounds: bounds }
        end

        def bounds_from_index(key, root)
          return unless key

          node = @index_builder.node_for(key)
          reference = node&.chunk_refs&.find { |ref| ref[:key] == key }
          bounds = reference && reference[:bounds]
          bounds if bounds_valid?(bounds)
        end

        def bounds_from_visibility(view, key)
          return unless view
          return unless view.respond_to?(:chunk_bounds)

          bounds = view.chunk_bounds(key)
          bounds if bounds_valid?(bounds)
        rescue StandardError
          nil
        end

        def chunk_bounds(chunk)
          return if empty_chunk?(chunk)

          bounds = chunk&.metadata && (chunk.metadata[:bounds] || chunk.metadata['bounds'])
          bounds if bounds_valid?(bounds)
        end

        def empty_chunk?(chunk)
          return true if chunk.respond_to?(:empty?) && chunk.empty?

          metadata = chunk.respond_to?(:metadata) ? chunk.metadata : nil
          metadata.is_a?(Hash) && (metadata[:empty] || metadata['empty'])
        end

        def bounds_valid?(bounds)
          return false unless bounds.is_a?(Hash)

          min = bounds[:min] || bounds['min']
          max = bounds[:max] || bounds['max']
          return false unless min.is_a?(Array) && max.is_a?(Array)
          return false unless min.length >= 3 && max.length >= 3

          (0..2).all? do |axis|
            mn = min[axis]
            mx = max[axis]
            next false if mn.nil? || mx.nil?

            numeric?(mn) && numeric?(mx)
          end
        end

        def numeric?(value)
          value.respond_to?(:to_f)
        end

        def include_candidate?(cosine, camera_forward, camera_position)
          return false unless camera_forward && camera_position
          return false if cosine.nil?

          cosine >= @forward_cosine_threshold
        end

        def priority_score(cosine, distance, near_visible)
          angle_penalty = 1.0 - (cosine || 0.0)
          distance_penalty = distance || Float::INFINITY
          score = angle_penalty * @angle_weight + distance_penalty * @distance_weight
          near_visible ? score * 0.1 : score
        end

        def ordered_prefetch_keys(candidates)
          candidates
            .sort_by do |candidate|
              [
                candidate[:near_visible] ? 0 : 1,
                candidate[:priority],
                candidate[:distance]
              ]
            end
            .map { |candidate| candidate[:key] }
            .uniq
        end

        def effective_prefetch_limit(budget:, max_prefetch:)
          limits = []
          limits << budget if budget.is_a?(Numeric) && budget.positive?
          limits << max_prefetch if max_prefetch.is_a?(Numeric) && max_prefetch.positive?
          return nil if limits.empty?

          limits.min
        end

        def available_prefetch_capacity(precomputed_count = nil)
          return unless @chunk_store.respond_to?(:max_in_memory)
          return unless @chunk_store.respond_to?(:each_in_memory)

          max = @chunk_store.max_in_memory
          return unless max && max.positive?

          in_memory = precomputed_count || @chunk_store.each_in_memory.count
          remaining = max - in_memory
          return 0 if remaining <= 0

          remaining
        end
      end
    end
  end
end
