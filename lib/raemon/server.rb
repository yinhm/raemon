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
        initialize_application

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
      
      def console!
        initialize_application
      end
      
      def initialize_application
        load_environment
        load_initializers
        load_lib
        
        initialize_logger
      end
      
      def initialize_logger
        return if !config.logger.nil?

        # Create our own logger if one wasn't provided
        if config.detach
          config.logger = Logger.new("#{RAEMON_ROOT}/log/#{server_name_key}.log")
        else
          config.logger = Logger.new(STDOUT)
        end
        
        # Set the logger level
        config.logger.level = instance_eval("Logger::#{config.log_level.to_s.upcase}")
        
        # TODO: format the logger
        # config.logger.formatter
      end
      
      def load_environment
        environment_file = "#{RAEMON_ROOT}/config/environments/#{RAEMON_ENV}.rb"
        eval IO.read(environment_file), binding
      end
      
      def load_initializers
        load_folder "#{RAEMON_ROOT}/config/initializers"
      end

      def load_lib
        libdir = "#{RAEMON_ROOT}/lib"
        $LOAD_PATH.unshift libdir
        load_folder libdir
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
