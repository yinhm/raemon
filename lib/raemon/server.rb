RAEMON_ENV = (ENV['RAEMON_ENV'] || 'development').dup unless defined?(RAEMON_ENV)

module Raemon
  module Server
    
    class << self
      attr_accessor :config
      
      def run
        @config = Configuration.new if config.nil?
        yield config if block_given?
      end
      
      def startup!
        load_environment
        load_initializers
        load_lib
        
        initialize_logger

        # Check if the server is already running
        if running?
          STDERR.puts "Error: #{server_name} is already running."
          exit
        end

        # Start the master daemon
        config.logger.info "=> Booting #{server_name} (#{RAEMON_ENV})"
        
        worker_klass = instance_eval(config.worker_klass)
        
        Raemon::Master.startup config.num_workers, worker_klass, {
          :detach   => config.detach,
          :logger   => config.logger,
          :pid_file => pid_file
        }
      end
      
      def shutdown!
        Raemon::Master.shutdown pid_file
      end
      
      def initialize_logger
        return if !config.logger.nil?
        
        if config.detach
          config.logger = Logger.new("#{RAEMON_ROOT}/log/#{server_name_key}.log")
        else
          config.logger = Logger.new(STDOUT)
        end
        
        # TODO: format the logger
        # config.logger.format
      end
      
      def load_environment
        environment_file = "#{RAEMON_ROOT}/config/environments/#{RAEMON_ENV}.rb"
        eval IO.read(environment_file), binding
      end
      
      def load_initializers
        load_folder("#{RAEMON_ROOT}/config/initializers")
      end

      def load_lib
        load_folder("#{RAEMON_ROOT}/lib")
      end
      
      def load_folder(path)
        Dir.entries(path).each do |lib_file|
          if lib_file != '.' && lib_file != '..'
            require "#{path}/#{lib_file}"
          end
        end
      end
      
      def server_name
        @server_name = config.name || 'Raemon'
      end
      
      def server_name_key
        server_name.downcase.gsub(' ', '_')
      end
      
      def pid_file
        "#{RAEMON_ROOT}/tmp/pids/#{server_name_key}.pid"
      end
      
      def running?
        # TODO
        false
      end
    end
    
    class Configuration
      ATTRIBUTES = [ :name, :detach, :worker_klass, :num_workers, :log_level, :logger ]

      attr_accessor *ATTRIBUTES
      
      def [](key)
        send key rescue nil
      end
    end
    
  end
end
