# frozen_string_literal: true

require 'thread'
require 'timeout'

module PointCloudPlugin
  module Bridge
    # Thread safe queue that marshals work to SketchUp's main thread via timers.
    class MainThreadQueue
      MAX_JOBS_PER_TICK = 50
      QUEUE_WARNING_THRESHOLD = 100
      DEFAULT_INTERVAL = 0.05
      EXECUTION_BUDGET = 0.02

      def initialize(interval: DEFAULT_INTERVAL, execution_budget: EXECUTION_BUDGET)
        @queue = Queue.new
        @interval = interval
        @execution_budget = execution_budget
        @timer = nil
      end

      def push(&block)
        @queue << block if block
        start_timer
      end

      def push_sync(&block)
        await(push_blocking(&block))
      end

      def push_blocking(&block)
        promise = JobPromise.new
        return promise.fulfill(nil) unless block

        if Thread.current == Thread.main || !timer_available?
          begin
            result = block.call
            promise.fulfill(result)
          rescue StandardError => e
            promise.reject(e)
          end
          return promise
        end

        wrapped = proc do
          begin
            result = block.call
            promise.fulfill(result)
          rescue StandardError => e
            promise.reject(e)
          end
        end

        push(&wrapped)

        promise
      end

      def await(promise, timeout: nil)
        return nil unless promise.respond_to?(:await)

        promise.await(timeout)
      end

      def drain
        backlog = @queue.size
        if backlog > QUEUE_WARNING_THRESHOLD && PointCloudPlugin.respond_to?(:log)
          PointCloudPlugin.log("MainThreadQueue backlog: #{backlog} jobs pending")
        end

        processed = 0
        start_time = monotonic_time

        while processed < MAX_JOBS_PER_TICK
          job = begin
            @queue.pop(true)
          rescue ThreadError
            nil
          end
          break unless job

          job.call
          processed += 1

          break if time_budget_exhausted?(start_time)
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

      def timer_available?
        defined?(UI) && UI.respond_to?(:start_timer)
      end

      def time_budget_exhausted?(start_time)
        return false unless @execution_budget && @execution_budget.positive?

        (monotonic_time - start_time) >= @execution_budget
      end

      def monotonic_time
        if Process.const_defined?(:CLOCK_MONOTONIC)
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        else
          Process.clock_gettime(:monotonic)
        end
      rescue Errno::EINVAL
        Time.now.to_f
      end

      # Lightweight promise implementation used to await completion of queued jobs.
      class JobPromise
        def initialize
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @completed = false
          @value = nil
          @error = nil
        end

        def fulfill(value)
          resolve(:value, value)
        end

        def reject(error)
          resolve(:error, error)
        end

        def await(timeout = nil)
          deadline = timeout ? monotonic_time + timeout.to_f : nil

          @mutex.synchronize do
            until @completed
              if deadline
                remaining = deadline - monotonic_time
                raise Timeout::Error, 'MainThreadQueue job timed out' if remaining <= 0.0

                @condition.wait(@mutex, remaining)
              else
                @condition.wait(@mutex)
              end
            end

            raise @error if @error

            @value
          end
        end

        private

        def resolve(type, payload)
          @mutex.synchronize do
            return self if @completed

            @completed = true
            if type == :error
              @error = payload
            else
              @value = payload
            end
            @condition.broadcast
          end

          self
        end

        def monotonic_time
          if Process.const_defined?(:CLOCK_MONOTONIC)
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          else
            Process.clock_gettime(:monotonic)
          end
        rescue Errno::EINVAL
          Time.now.to_f
        end
      end
    end
  end
end
