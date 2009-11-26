module Sampled
  
  class Worker
    include Raemon::Worker
    
    def start
      logger.info "Start .. #{Process.ppid}:#{Process.pid}"
    end

    def stop
      logger.info "=> Stopping worker #{Process.pid}"
      exit
    end

    def execute
      loop do
        stop if shutting_down?

        logger.warn "I'm executing .. #{Process.ppid}:#{Process.pid}"
        sleep 2
      end
    end
  end
  
end
