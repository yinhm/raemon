module Raemon
  class Master
    attr_reader :worker_pids
    attr_reader :worker_klass
    attr_reader :logger
    
    def self.startup(num_workers, worker_klass, opts={})
      master = new(opts)
      master.startup(num_workers, worker_klass)
    end
    
    def self.shutdown(pid_file)
      pid = File.open(pid_file, 'r') {|f| f.gets }.to_i
      Process.kill('TERM', pid) if pid > 0
      File.unlink(pid_file)
    rescue Errno::ESRCH
    end
    
    def initialize(opts={})
      @detach         = opts[:detach] || false
      @logger         = opts[:logger] || Logger.new(STDOUT)
      @pid_file       = opts[:pid_file]
      @worker_pids    = []
      
      daemonize if @detach
    end
    
    def startup(num_workers, worker_klass)
      logger.info "=> Starting Raemon::Master with #{num_workers} worker(s)"
      
      @worker_klass = worker_klass
      
      # Check if the worker implements our protocol
      if !worker_klass.include?(Raemon::Worker)
        logger.error "** Invalid Raemon worker"
        exit
      end
      
      # Spawn workers
      num_workers.times { worker_pids << worker_klass.start!(self) }
      
      # Setup signals for the master process
      setup_signals
      
      # Wait for all the workers
      Process.waitall
      
      logger.close
    end
    
    def shutdown
      @worker_pids.each { |wpid| worker_klass.stop!(wpid) }
    end
    
    def daemonize
      exit if Kernel.fork
      
      Process.setsid
    
      Dir.chdir '/'
      File.umask 0000

      STDIN.reopen '/dev/null'
      STDOUT.reopen '/dev/null', 'a'
      STDERR.reopen '/dev/null', 'a'
      
      File.open(@pid_file, 'w') { |f| f.puts(Process.pid) } if @pid_file
    end
    
    def setup_signals
      shutdown_block = Proc.new { shutdown }
      
      trap('INT', shutdown_block)
      trap('TERM', shutdown_block)
    end
    
    def debugging?; @debug; end
    
  end
end
