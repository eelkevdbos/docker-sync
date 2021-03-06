require 'thor/shell'
# noinspection RubyResolve
require 'docker-sync/sync_process'
# noinspection RubyResolve
require 'docker-sync/execution'
require 'yaml'
require 'dotenv'
require 'docker-sync/config_template'

module Docker_sync
  class SyncManager
    include Thor::Shell

    @sync_processes
    @configurations
    @config_path

    def initialize(options)
      Dotenv.load

      @sync_processes = []
      @config_syncs = []
      @config_global = []
      @config_string = options[:config_string]
      @config_path = options[:config_path]
      load_configuration
    end

    def load_configuration_file
      unless File.exist?(@config_path)
        raise "Config could not be loaded from #{@config_path} - it does not exist"
      end
      return File.read(@config_path)
    end
    
    def load_configuration
      
      # try to interpolate supplied inline config string, alternatively load the configuration file
      config = ConfigTemplate::interpolate_config_string(@config_string || load_configuration_file())

      validate_config(config)
      @config_global = config['options'] || {}
      @config_syncs = config['syncs']
      upgrade_syncs_config
    end

    def global_options
      return @config_global
    end

    def get_sync_points
      return @config_syncs
    end

    def upgrade_syncs_config
      @config_syncs.each do |name, config|
        @config_syncs[name]['config_path'] = @config_path

        # [nbr] convert the sync src from relative to absolute path
        #	preserve '/' as it may be significant to the sync cmd
              absolute_path = File.expand_path(@config_syncs[name]['src'])
        absolute_path << "/" if @config_syncs[name]['src'].end_with?("/")
        @config_syncs[name]['src'] = absolute_path

        @config_syncs[name]['cli_mode'] = @config_global['cli_mode'] || 'auto'

        # set the global verbose setting, if the sync-endpoint does not define a own one
        unless config.key?('verbose')
          @config_syncs[name]['verbose'] = false
          if @config_global.key?('verbose')
            @config_syncs[name]['verbose'] = @config_global['verbose']
          end
        end

        # for each strategy check if a custom image has been defined and inject that into the sync-endpoints
        # which do fit for this strategy
        %w(rsync unison).each do |strategy|
          if config.key?("#{strategy}_image") && @config_syncs[name]['sync_strategy'] == strategy
            @config_syncs[name]['image'] = config["#{strategy}_image"]
          end
        end
      end
    end

    def validate_config(config)
      unless config.key?('syncs')
        raise ('no syncs defined')
      end

      config['syncs'].each do |name, sync_config|
        validate_sync_config(name, sync_config)
      end

      return true
    end

    def validate_sync_config(name, sync_config)
      config_mandatory = %w[src dest]
      config_mandatory.push('sync_host_port') if sync_config['sync_strategy'] == 'rsync' #TODO: Implement autodisovery for other strategies
      config_mandatory.each do |key|
        raise ("#{name} does not have #{key} configuration value set - this is mandatory") unless sync_config.key?(key)
      end
    end

    def init_sync_processes(sync_name = nil)
      return if @sync_processes.size != 0
      if sync_name.nil?
        @config_syncs.each { |name, sync_configuration|
          @sync_processes.push(create_sync(name, sync_configuration))
        }
      else
        unless @config_syncs.key?(sync_name)
          raise("Could not find sync configuration with name #{sync_name}")
        end
        @sync_processes.push(create_sync(sync_name, @config_syncs[sync_name]))
      end
    end


    def clean(sync_name = nil)
      init_sync_processes(sync_name)
      @sync_processes.each { |sync_process|
        sync_process.clean
      }
    end

    def sync(sync_name = nil)
      init_sync_processes(sync_name)
      @sync_processes.each { |sync_process|
        sync_process.sync
      }
    end

    def start_container(sync_name = nil)
      init_sync_processes(sync_name)
      @sync_processes.each { |sync_process|
        sync_process.start_container
      }
    end

    def run(sync_name = nil)
      init_sync_processes(sync_name)

      @sync_processes.each { |sync_process|
        sync_process.run
      }
    end

    def join_threads
      begin
        @sync_processes.each do |sync_process|
          if sync_process.watch_thread
            sync_process.watch_thread.join
          end
          if sync_process.watch_fork
            Process.wait(sync_process.watch_fork)
          end
        end

      rescue SystemExit, Interrupt
        say_status 'shutdown', 'Shutting down...', :blue
        @sync_processes.each do |sync_process|
          sync_process.stop
        end

      rescue Exception => e
        puts "EXCEPTION: #{e.inspect}"
        puts "MESSAGE: #{e.message}"
      end
    end

    def create_sync(sync_name, sync_configuration)
      sync_process = Docker_Sync::SyncProcess.new(sync_name, sync_configuration)
      return sync_process
    end

    def stop
      @sync_processes.each { |sync_process|
        sync_process.stop
        unless sync_process.watch_thread.nil?
          sync_process.watch_thread.kill unless sync_process.watch_thread.nil?
        end
      }
    end

    def watch_stop
      @sync_processes.each { |sync_process|
        sync_process.watch_thread.kill unless sync_process.watch_thread.nil?
      }
    end

    def watch_start
      @sync_processes.each { |sync_process|
        sync_process.watch
      }
    end
  end
end
