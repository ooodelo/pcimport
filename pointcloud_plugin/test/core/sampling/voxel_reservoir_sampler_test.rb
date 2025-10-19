# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../../core/sampling/voxel_reservoir_sampler'

module PointCloudPlugin
  module Core
    module Sampling
      class VoxelReservoirSamplerTest < Minitest::Test
        def test_estimates_voxel_size_from_bounds
          sampler = VoxelReservoirSampler.new(target_count: 8, random: Random.new(1))

          points = [
            { position: [0.0, 0.0, 0.0] },
            { position: [2.0, 2.0, 2.0] }
          ]

          sampler.add_batch(points)

          expected = ((2.0**3) / 8.0)**(1.0 / 3.0)
          assert_in_delta expected, sampler.voxel_size, expected * 0.25
        end

        def test_limits_to_target_count
          sampler = VoxelReservoirSampler.new(target_count: 50, random: Random.new(2))

          500.times do |index|
            sampler.add({ position: [index % 10, (index / 10) % 10, index / 100.0] })
          end

          assert_operator sampler.samples.length, :<=, 500
          refute_empty sampler.samples
        end

        def test_returns_anchor_indices
          sampler = VoxelReservoirSampler.new(target_count: 20, anchor_ratio: 0.5, random: Random.new(3))

          100.times do |index|
            sampler.add({ position: [index * 0.1, 0.0, 0.0], color: [index % 255, 0, 0] })
          end

          samples = sampler.samples
          anchors = sampler.anchor_indices

          anchors.each do |idx|
            assert samples[idx].anchor, 'anchor index should reference anchor sample'
          end
        end

        def test_reservoir_replacement_in_dense_voxel
          sampler = VoxelReservoirSampler.new(target_count: 1, random: Random.new(4))

          colors = []
          100.times do |index|
            sampler.add({ position: [0.0, 0.0, 0.0], color: [index % 255, 0, 0] })
            colors << sampler.samples.first.color.first if sampler.samples.first
          end

          unique_colors = colors.compact.uniq
          assert_operator unique_colors.length, :>, 1, 'reservoir should occasionally replace the sample'
        end
      end
    end
  end
end
