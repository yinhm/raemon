module Raemon
  module Worker
    
    def self.included(base)
      base.send :include, InstanceMethods
    end
    
    module InstanceMethods
      attr_reader :logger
      attr_accessor :nr
      attr_accessor :tmp
      
      def initialize(master, nr, tmp)
        @master = master
        @logger = master.logger if master
        self.nr = nr
        self.tmp = tmp
        
        before_start if self.respond_to? :before_start
      end

      # worker objects may be compared to just plain numbers
      def ==(other_nr)
        self.nr == other_nr
      end

      def execute
        raise "Abstract method"
      end

      def shutdown
        Timeout::timeout(5) do
          before_shutdown rescue nil if self.respond_to? :before_shutdown
        end
      ensure
        exit!(0)
      end
    end
    
  end
end
