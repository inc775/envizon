require 'socket'
require 'open3'

class ScanWorker
  require 'nmap_parser'
  include Sidekiq::Worker
  #sidekiq_options queue: 'scan'
  sidekiq_options queue: 'default' #!
  sidekiq_options retry: false
  #sidekiq_options retry: 0
  def perform(args)
    ActiveRecord::Base.connection_pool.with_connection do
      return_value = nil
      scan = Scan.find(args['scan_id'])
      cmd = args['cmd']
      options = args['options'].split

      env = ENV
      unless Process.uid.zero? # && askpass # wut?
        env = askpass
        options.unshift 'nmap'
        options.unshift '-A'
        cmd = 'sudo'
      end

      puts cmd
      puts options
      Open3.popen3(env, cmd, *options) do |_stdin, stdout, _stderr, thread|
        stdout.each do |l|
          l.match(/About (.*) done/) do |m|
            puts m
            c = m.captures.first
            scan.status = c.match(/\A(\d+)\.\d+\%\Z/).captures.first.to_i
            scan.save
            next unless User.first.settings.where(name: 'global_notify').first.value.include? "true"
            message = "Scan #{scan.name} - #{args['run_counter']}/#{args['max_run_counter']} is #{c} done."
            ActionCable.server.broadcast 'notification_channel', message: message
          end
          # TODO: message on fail?
          # exception?
          # parse nmap errors if it doesn't like the options
        end
        # let's do some generic error handling in the meantime:
        return_value = thread.value
        puts "return value #{return_value}"
      end
      if return_value.success?
        # trigger parser worker
        scan.enddate = Time.now
        scan.save
        args_parse = {
          'xmlpath' => args['filename'], 
          'scan_id' => args['scan_id'], 
          'user_id' => args['user_id'],
          'run_coutner' => args['run_counter'],
          'max_run_counter' => args['max_run_counter']
        }
        ScanParseWorker.perform_async(args_parse)
      else
        # send error message
        message = "Nmap threw an error: #{return_value.exitstatus}!"
        ActionCable.server.broadcast 'notification_channel', message: message
        scan.command = 'Scan failed.'
        scan.save
      end
    end
  end

  def askpass
    env = ENV.clone
    env['SUDO_ASKPASS'] = if ENV['SUDO_ASKPASS'].present? && File.exist?(ENV['SUDO_ASKPASS'])
                            ENV['SUDO_ASKPASS']
                          elsif File.exist?('/usr/lib/ssh/x11-ssh-askpass')
                            '/usr/lib/ssh/x11-ssh-askpass'
                          else
                            ''
                          end
    # TODO: that was somewhat stupid. probably should only send out a message if
    # nmap itself returns privilege-related failure.
    # So basically: rewrite sudo handling
    # message = 'Couldn\'t get root privileges, please set SUDO_ASKPASS'
    # ActionCable.server.broadcast 'notification_channel', message: message
    env['SUDO_ASKPASS'].present? ? env : false
  end
=begin
  def perform(args)
    ActiveRecord::Base.connection_pool.with_connection do

      command = NmapCommand.new(args['command'], args['user_id'], args['target'])
      scan = Scan.new(name: args['scan_name'], user_id: args['user_id'])
      scan.command = 'Scan in progress…'
      scan.save

      #num_workers =  user.settings.find_by_name('parallel_scans').value.to_i
      # rm? will be overwritten in parser
      scan.startdate = Time.now
      scan.save
      while command.run_counter < command.max_run_counter
        filename = command.run(scan)
        scan.enddate = Time.now
        scan.save
        args_parse = {
          'xmlpath' => filename, 
          'scan_id' => scan.id, 
          'user_id' => args['user_id'],
          'run_coutner' => command.run_counter,
          'max_run_counter' => command.max_run_counter
        }
        ScanParseWorker.perform_async(args_parse)
      end
    end
  end
=end
end
