require_relative 'session'

module Kaitoio
  module Agent
    # In-SketchUp end-to-end check: viewport -> image -> video, driven by the
    # same Session the Agent panel uses.
    #
    # Runs as a UI.start_timer state machine rather than a blocking script:
    # a video generation takes minutes, and blocking the main thread would
    # freeze SketchUp for the duration.
    module SelfTest
      module_function

      IMAGE_NODE = 'builtin/third_party/fal/qwen_image_edit'.freeze
      VIDEO_NODE = 'builtin/third_party/fal/seedance_2_i2v'.freeze
      IMAGE_PROMPT = 'Photorealistic modern city plaza at golden hour, natural sunlight, architectural backdrop'.freeze
      VIDEO_PROMPT = 'Slow cinematic dolly forward, gentle camera push, natural motion'.freeze
      STEP_TIMEOUT = 600

      def running?
        !@timer.nil?
      end

      def run!(image_node: IMAGE_NODE, video_node: VIDEO_NODE)
        return say('already running') if running?

        @image_node = image_node
        @video_node = video_node
        @state      = :capture
        @started    = Time.now
        @results    = {}
        # The user starts this deliberately, so paid runs are pre-approved.
        Kaitoio::Agent::Session.allow_cost!

        say("start — #{image_node} then #{video_node}")
        @timer = UI.start_timer(1, true) { tick }
        true
      end

      def stop!
        UI.stop_timer(@timer) if @timer
        @timer = nil
      end

      def say(msg)
        Kaitoio.log("[self-test] #{msg}")
        panel = Kaitoio::Dialogs::AgentDialog
        panel.push('agent_tool', 'ok' => true,
                   'data' => { 'tool' => 'self-test', 'phase' => 'start', 'detail' => msg }) rescue nil
        nil
      end

      # One step per tick; long waits poll instead of blocking.
      def tick
        case @state
        when :capture       then do_capture
        when :run_image     then do_run(@image_node, IMAGE_PROMPT, :wait_image)
        when :wait_image    then do_wait(:collect_image)
        when :collect_image then do_collect(:image, :attach_image)
        when :attach_image  then do_attach_result
        when :run_video     then do_run(@video_node, VIDEO_PROMPT, :wait_video)
        when :wait_video    then do_wait(:collect_video)
        when :collect_video then do_collect(:video, :finish)
        when :finish        then do_finish
        end
      rescue => e
        say("FAILED in #{@state}: #{e.class}: #{e.message}")
        stop!
      end

      def do_capture
        shot = Kaitoio::Render.capture_view
        say("captured #{shot['width']}x#{shot['height']}")
        name = Kaitoio::Agent::Session.attach_capture(shot['path'])
        say("attached #{name}")
        @state = :run_image
      end

      def do_run(node, prompt, next_state)
        say("running #{node.split('/').last}")
        res = Kaitoio::Agent::Session.run_exact(node, node, "selftest-#{Time.now.to_i}", prompt)
        @exec_id = res['executionId']
        raise "no execution id (#{res['kind']})" unless @exec_id
        @deadline = Time.now + STEP_TIMEOUT
        @last_pct = nil
        say("execution #{@exec_id}")
        @state = next_state
      end

      def do_wait(next_state)
        body = Kaitoio::Agent::Session.poll(@exec_id)['structured'] || {}
        status = (body['status'] || body['state']).to_s.downcase
        pct = Kaitoio::Agent::Session.events(@exec_id)
                                    .map { |e| e['progress'] }.compact
                                    .map { |v| (v.to_f * 100).round }.max
        if pct && pct != @last_pct
          @last_pct = pct
          say("#{status} #{pct}%")
        end

        if %w[failed error canceled cancelled].include?(status)
          raise "run #{status}"
        elsif %w[succeeded success completed complete done finished].include?(status)
          @state = next_state
        elsif Time.now > @deadline
          raise "timed out after #{STEP_TIMEOUT}s (last status #{status})"
        end
      end

      def do_collect(kind, next_state)
        out = Kaitoio::Agent::Session.collect_output(@exec_id, "self-test #{kind}")
        return say('outputs still settling') if out['kind'] == 'pending'
        raise "no media: #{out['text'].to_s[0, 160]}" unless out['kind'] == 'media'

        path = out['entry']['path']
        @results[kind] = path
        say("#{kind.upcase} #{File.basename(path)} (#{File.size(path)} bytes, #{out['entry']['contentType']})")
        @state = next_state
      end

      def do_attach_result
        name = Kaitoio::Agent::Session.attach_capture(@results[:image])
        say("attached generated image as #{name}")
        @state = :run_video
      end

      def do_finish
        stop!
        elapsed = (Time.now - @started).round
        say("PASS in #{elapsed}s")
        say("image: #{@results[:image]}")
        say("video: #{@results[:video]}")
        UI.messagebox("Kaitoio self-test passed in #{elapsed}s\n\n" \
                      "Image: #{@results[:image]}\nVideo: #{@results[:video]}")
        Kaitoio::Render.open_file(@results[:video]) if @results[:video]
      end
    end
  end
end
