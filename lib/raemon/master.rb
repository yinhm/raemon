module Raemon
  class Master < Struct.new(:timeout, :worker_processes, :worker_klass,
                            :detach, :logger, :pid_file, :master_pid)
    #attr_reader :worker_pids

    # The basic max request size we'll try to read.
    CHUNK_SIZE=(16 * 1024)
    
    # This hash maps PIDs to Workers
    WORKERS = {}
    
    # We use SELF_PIPE differently in the master and worker processes:
    #
    # * The master process never closes or reinitializes this once
    # initialized.  Signal handlers in the master process will write to
    # it to wake up the master from IO.select in exactly the same manner
    # djb describes in http://cr.yp.to/docs/selfpipe.html
    #
    # * The workers immediately close the pipe they inherit from the
    # master and replace it with a new pipe after forking.  This new
    # pipe is also used to wakeup from IO.select from inside (worker)
    # signal handlers.  However, workers *close* the pipe descriptors in
    # the signal handlers to raise EBADF in IO.select instead of writing
    # like we do in the master.  We cannot easily use the reader set for
    # IO.select because LISTENERS is already that set, and it's extra
    # work (and cycles) to distinguish the pipe FD from the reader set
    # once IO.select returns.  So we're lazy and just close the pipe when
    # a (rare) signal arrives in the worker and reinitialize the pipe later.
    SELF_PIPE = []
    
    # signal queue used for self-piping
    SIG_QUEUE = []

    def self.startup(num_workers, worker_klass, opts={})
      master = new(opts)
      master.startup(num_workers, worker_klass)
    end
    
    def self.shutdown(pid_file)
      pid = File.open(pid_file, 'r') {|f| f.gets }.to_i
      Process.kill('TERM', pid) if pid > 0
      #File.unlink(pid_file)
    rescue Errno::ESRCH
    end
    
    def initialize(opts={})
      self.detach = opts[:detach] || false
      self.logger = opts[:logger] || Logger.new(STDOUT)
      self.pid_file = opts[:pid_file]
      self.timeout = 60
      # @worker_pids = []
      
      daemonize if detach
    end
    
    def startup(num_workers, worker_klass)
      self.worker_processes = num_workers
      self.worker_klass = worker_klass

      logger.info "=> starting Raemon::Master with #{worker_processes} worker(s)"
      
      # Check if the worker implements our protocol
      if !worker_klass.include?(Raemon::Worker)
        logger.error "** invalid Raemon worker"
        exit
      end
      
      self.master_pid = $$
      
      # Spawn workers
      maintain_worker_count
      
      reap_all_workers
      
      self
    end
    
    # monitors children and receives signals forever
    # (or until a termination signal is sent).  This handles signals
    # one-at-a-time time and we'll happily drop signals in case somebody
    # is signalling us too often.
    def join
      # this pipe is used to wake us up from select(2) in #join when signals
      # are trapped.  See trap_deferred
      init_self_pipe!
      respawn = true
      last_check = Time.now

      QUEUE_SIGS.each { |sig| trap_deferred(sig) }
      trap(:CHLD) { |sig_nr| awaken_master }
      proc_name 'master'
      logger.info "=> master process ready" # test_exec.rb relies on this message
      begin
        loop do
          reap_all_workers
          case SIG_QUEUE.shift
          when nil
            # avoid murdering workers after our master process (or the
            # machine) comes out of suspend/hibernation
            if (last_check + timeout) >= (last_check = Time.now)
              murder_lazy_workers
            end
            maintain_worker_count if respawn
            master_sleep
          when :QUIT # graceful shutdown
            break
          when :TERM, :INT # immediate shutdown
            stop(false)
            break
          when :WINCH
            if Process.ppid == 1 || Process.getpgrp != $$
              respawn = false
              logger.info "gracefully stopping all workers"
              kill_each_worker(:QUIT)
            else
              logger.info "SIGWINCH ignored because we're not daemonized"
            end
          end
        end
      rescue Errno::EINTR
        retry
      rescue => e
        logger.error "Unhandled master loop exception #{e.inspect}."
        logger.error e.backtrace.join("\n")
        retry
      end
      stop # gracefully shutdown all workers on our way out
      logger.info "master complete"
      unlink_pid_safe(pid_file) if pid_file
    end

    # Terminates all workers, but does not exit master process
    def stop(graceful = true)
      #self.listeners = []
      timeout = 30
      limit = Time.now + timeout
      until WORKERS.empty? || Time.now > limit
        kill_each_worker(graceful ? :QUIT : :TERM)
        sleep(0.1)
        reap_all_workers
      end
      kill_each_worker(:KILL)
    end

    def daemonize
      exit if Process.fork
      
      Process.setsid
    
      Dir.chdir '/'
      File.umask 0000

      STDIN.reopen '/dev/null'
      STDOUT.reopen '/dev/null', 'a'
      STDERR.reopen '/dev/null', 'a'
      
      File.open(pid_file, 'w') { |f| f.puts(Process.pid) } if pid_file
    end
    
    private
    # list of signals we care about and trap in master.
    QUEUE_SIGS = [ :WINCH, :QUIT, :INT, :TERM, :USR1, :USR2, :HUP,
                   :TTIN, :TTOU ]

    # defer a signal for later processing in #join (master process)
    def trap_deferred(signal)
      trap(signal) do |sig_nr|
        if SIG_QUEUE.size < 5
          SIG_QUEUE << signal
          awaken_master
        else
          logger.error "ignoring SIG#{signal}, queue=#{SIG_QUEUE.inspect}"
        end
      end
    end
    
    # wait for a signal hander to wake us up and then consume the pipe
    # Wake up every second anyways to run murder_lazy_workers
    def master_sleep
      begin
        ready = IO.select([SELF_PIPE.first], nil, nil, 1) or return
        ready.first && ready.first.first or return
        loop { SELF_PIPE.first.read_nonblock(CHUNK_SIZE) }
      rescue Errno::EAGAIN, Errno::EINTR
      end
    end

    def awaken_master
      begin
        SELF_PIPE.last.write_nonblock('.') # wakeup master process from select
      rescue Errno::EAGAIN, Errno::EINTR
        # pipe is full, master should wake up anyways
        retry
      end
    end

    # reaps all unreaped workers
    def reap_all_workers
      begin
        loop do
          wpid, status = Process.waitpid2(-1, Process::WNOHANG)
          wpid or break
          worker = WORKERS.delete(wpid) and worker.tmp.close rescue nil
          logger.info "=> reaped #{status.inspect} " \
                      "worker=#{worker.nr rescue 'unknown'}"
        end
      rescue Errno::ECHILD
      end
    end

    # forcibly terminate all workers that haven't checked in in timeout
    # seconds.  The timeout is implemented using an unlinked File
    # shared between the parent process and each worker.  The worker
    # runs File#chmod to modify the ctime of the File.  If the ctime
    # is stale for >timeout seconds, then we'll kill the corresponding
    # worker.
    def murder_lazy_workers
      WORKERS.dup.each_pair do |wpid, worker|
        stat = worker.tmp.stat
        # skip workers that disable fchmod or have never fchmod-ed
        stat.mode == 0100600 and next
        (diff = (Time.now - stat.ctime)) <= timeout and next
        logger.error "=> worker=#{worker.nr} PID:#{wpid} timeout " \
                     "(#{diff}s > #{timeout}s), killing"
        kill_worker(:KILL, wpid) # take no prisoners for timeout violations
      end
    end

    def spawn_missing_workers
      (0...worker_processes).each do |worker_nr|
        WORKERS.values.include?(worker_nr) and next
        worker = worker_klass.new(self, worker_nr, Raemon::Util.tmpio)
        #before_fork.call(self, worker)
        WORKERS[fork { worker_loop(worker) }] = worker
      end
    end

    def maintain_worker_count
      (off = WORKERS.size - worker_processes) == 0 and return
      off < 0 and return spawn_missing_workers
      WORKERS.dup.each_pair { |wpid,w|
        w.nr >= worker_processes and kill_worker(:QUIT, wpid) rescue nil
      }
    end

    # gets rid of stuff the worker has no business keeping track of
    # to free some resources and drops all sig handlers.
    def init_worker_process(worker)
      QUEUE_SIGS.each { |sig| trap(sig, nil) }
      trap(:CHLD, 'DEFAULT')
      SIG_QUEUE.clear
      proc_name "worker[#{worker.nr}]"
      init_self_pipe!
      WORKERS.values.each { |other| other.tmp.close rescue nil }
      WORKERS.clear
      #LISTENERS.each { |sock| sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
      worker.tmp.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      #after_fork.call(self, worker) # can drop perms
      self.timeout /= 2.0 # halve it for select()
    end
    
    # runs inside each forked worker, this sits around and waits
    # for connections and doesn't die until the parent dies (or is
    # given a INT, QUIT, or TERM signal)
    def worker_loop(worker)
      ppid = master_pid
      init_worker_process(worker)
      alive = worker.tmp # tmp is our lifeline to the master process
      #ready = LISTENERS

      # closing anything we IO.select on will raise EBADF
      trap(:QUIT) { alive = nil }
      [:TERM, :INT].each { |sig| trap(sig) { worker.shutdown } } # instant shutdown
      logger.info "=> worker=#{worker.nr} ready"
      m = 0

      begin
        # we're a goner in timeout seconds anyways if alive.chmod
        # breaks, so don't trap the exception.  Using fchmod() since
        # futimes() is not available in base Ruby and I very strongly
        # prefer temporary files to be unlinked for security,
        # performance and reliability reasons, so utime is out.  No-op
        # changes with chmod doesn't update ctime on all filesystems; so
        # we change our counter each and every time (after process_client
        # and before IO.select).
        alive.chmod(m = 0 == m ? 1 : 0)

        worker.execute
        
        ppid == Process.ppid or return
        alive.chmod(m = 0 == m ? 1 : 0)
        begin
          # timeout used so we can detect parent death:
          ret = IO.select(SELF_PIPE, nil, nil, timeout) or redo
          ready = ret.first
        # rescue Errno::EINTR
        rescue Errno::EBADF
          return
        end
      rescue => e
        if alive
          logger.error "Unhandled listen loop exception #{e.inspect}."
          logger.error e.backtrace.join("\n")
        end
      end while alive
    end

    # delivers a signal to a worker and fails gracefully if the worker
    # is no longer running.
    def kill_worker(signal, wpid)
      begin
        Process.kill(signal, wpid)
      rescue Errno::ESRCH
        worker = WORKERS.delete(wpid) and worker.tmp.close rescue nil
      end
    end
    
    # delivers a signal to each worker
    def kill_each_worker(signal)
      WORKERS.keys.each { |wpid| kill_worker(signal, wpid) }
    end

    # unlinks a PID file at given +path+ if it contains the current PID
    # still potentially racy without locking the directory (which is
    # non-portable and may interact badly with other programs), but the
    # window for hitting the race condition is small
    def unlink_pid_safe(path)
      (File.read(path).to_i == $$ and File.unlink(path)) rescue nil
    end

    def proc_name(tag)
      $0 = "raemon #{worker_klass.name} #{tag}"
    end

    def init_self_pipe!
      SELF_PIPE.each { |io| io.close rescue nil }
      SELF_PIPE.replace(IO.pipe)
      SELF_PIPE.each { |io| io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
    end
  end
end
