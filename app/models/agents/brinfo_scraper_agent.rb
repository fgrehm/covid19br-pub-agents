module Agents
  class BrinfoScraperAgent < Agent
    can_dry_run!

    UNIQUENESS_LOOK_BACK = 200

    description <<-MD
      The Brinfo Scrape Article Agent allows you to scrape articles using [brinfo](https://github.com/fgrehm/brinfo/).
    MD

    def default_options
      {
        'expected_update_period_in_days' => 1,
        'command' => 'article',
        'args' => ['{{ url }}'],
        'opts' => ['--source-guid=br-foo-bar'],
      }
    end

    def validate_options
      errors.add(:base, "command was not provided") if options['command'].blank?
    end

    def working?
      event_created_within?(interpolated['expected_update_period_in_days'] || 1) && !recent_error_logs?
    end

    def receive(incoming_events)
      incoming_events.each do |event|
        handle(interpolated(event))
      end
    end

    def check
      handle(interpolated)
    end

    private

    def handle(config, event = nil)
      command = ['./vendor/bin/brinfo-scrape', config['command']]
      command += config['opts']
      command += config['args']

      result, errors, exit_status = run_command(command)
      if exit_status.nonzero?
        5.times do |i|
          log("retrying... stderr=#{errors.inspect}")
          sleep 1 + i
          result, errors, exit_status = run_command(command)
          break if exit_status.zero?
        end
      end

      log("exit_status=#{exit_status} stderr=#{errors.inspect} stdout=#{result.truncate(100).inspect}")
      if exit_status.zero?
        results = JSON.parse(result)
        results = [results] unless results.is_a?(Array)
        store_payloads(results)
      end
    end

    def run_command(command)
      log("running #{command.inspect}")
      begin
        rout, wout = IO.pipe
        rerr, werr = IO.pipe
        rin,  _ = IO.pipe

        pid = spawn(*command, out: wout, err: werr, in: rin)

        wout.close
        werr.close
        rin.close

        (result = rout.read).strip!
        (errors = rerr.read).strip!

        _, status = Process.wait2(pid)
        exit_status = status.exitstatus
      rescue => e
        errors = e.to_s
        result = ''.freeze
        exit_status = nil
      end

      [result, errors, exit_status]
    end

    def store_payloads(results)
      old_events = events.order("id desc").limit(UNIQUENESS_LOOK_BACK)

      results.each do |res|
        result_json = res.to_json
        if found = old_events.find { |event| event.payload.to_json == result_json }
          found.update!(expires_at: new_event_expiration_date)
        else
          create_event(payload: res)
        end
      end
    end
  end
end
