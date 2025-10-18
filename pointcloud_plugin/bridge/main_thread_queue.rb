# frozen_string_literal: true

require 'thread'

module PointCloudPlugin
  module Bridge
    # Thread safe queue that marshals work to SketchUp's main thread via timers.
    class MainThreadQueue
      MAX_JOBS_PER_TICK = 50
      QUEUE_WARNING_THRESHOLD = 100

      def initialize(interval: 0.1)
        @queue = Queue.new
        @interval = interval
        @timer = nil
      end

      def push(&block)
        @queue << block if block
        start_timer
      end

      def drain
        backlog = @queue.size
        if backlog > QUEUE_WARNING_THRESHOLD && PointCloudPlugin.respond_to?(:log)
          PointCloudPlugin.log("MainThreadQueue backlog: #{backlog} jobs pending")
        end

        processed = 0
        while processed < MAX_JOBS_PER_TICK
          job = begin
            @queue.pop(true)
          rescue ThreadError
            nil
          end
          break unless job

          job.call
          processed += 1
        end
      end

      private

      def start_timer
        return if @timer
        if defined?(UI) && UI.respond_to?(:start_timer)
          @timer = UI.start_timer(@interval, true) do
            drain
          end
        end
      end
    end
  end
end
