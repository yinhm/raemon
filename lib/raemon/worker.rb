module Raemon
  module Worker
    
    def self.included(base)
      base.send :extend, ClassMethods
      base.send :include, InstanceMethods
    end
    
    module ClassMethods
      def start!(master=nil)
        child_pid = Kernel.fork do
          # Child process
          worker = new(master)
          worker.execute
        end
        
        # Parent returns the worker's pid
        return child_pid
      end
    
      def stop!(worker_pid)
        Process.kill('QUIT', worker_pid) rescue nil
      end
    end
    
    module InstanceMethods
      attr_reader :logger
      
      def initialize(master=nil)
        @master = master
        @logger = master.logger if master
        
        setup_signals
        start
      end
        
      def start;                                      end
      def stop;                                       end
      def shutting_down?;   @shutting_down;           end
      def execute;          raise "Abstract method";  end

      def setup_signals
        quit_block = Proc.new { @shutting_down = true }
        force_quit_block = Proc.new { exit }

        trap('QUIT', quit_block)
        trap('TERM', force_quit_block)
        trap('INT') {} # Reset INT signal handler
      end
    end
    
  end
end