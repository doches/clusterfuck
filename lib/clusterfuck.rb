require 'socket'
require 'net/ssh'

# Clusterfuck is an ugly, dirty hack to run a large number of jobs on multiple machines.
# If you can break your task up into a series of small, independent jobs, clusterfuck
# can automate the process of distributing jobs across machines.
module Clusterfuck
  # Print a message when a job is cancelled due to too many failures
  VERBOSE_CANCEL = 0
  # Print a message when a job is cancelled AND at each failure
  VERBOSE_FAIL = 1
  # Print a message for cancellations and failures, AND each time a job is started.
  VERBOSE_ALL = 2

  # The flag used to prefix dry run (debugging) messages.
  DEBUG_WARN = "[DRY-RUN]"
  # The interval to sleep instead of running jobs when performing a dry run (in seconds)
  DEBUG_INTERVAL = [0.2,1.0]

  # A configuration holds the various pieces of information Clusterfuck needs
  # to represent a task. 
  #
  # You probably won't need to instantiate a Configuration directly; one is created
  # when you create a new Task, and passed to the block it takes as a parameter. See Task
  # for more information.
  #
  # Possible configuration options include:
  # [timeout]     Number of seconds to wait before an SSH connection 'times out' (DEFAULT: 2)
  # [max_fail]    Max number of times a failing job will be re-attempted on a new machine (DEFAULT: 3)
  # [hosts]       Array of hostnames (or ip addresses) as Strings to use as nodes
  # [jobs]        Array of Job objects, one per job, which will be allocated to the +hosts+. If you're lazy,
  #               you can also just use an array of strings (where each string is the command to run) -- a short
  #               name for each will be produced using the first 8 chars from the command.
  # [verbose]     Level of message reporting. One of +VERBOSE_CANCEL+,+VERBOSE_FAIL+, or +VERBOSE_ALL+
  #               (DEFAULT: +VERBOSE_CANCEL+)
  # [username]    The SSH username to use to connect
  # [password]    The SSH password to use to connect
  # [show_report] Show a report after all jobs are complete that gives statistics for each machine.
  # [debug]       Do a 'dry run' -- allocate jobs to machines and display the result but DO NOT actually
  #               connect to any machines or run any jobs. Useful for testing your clusterfile before 
  #               kicking off a major run.
  # [temp]        Directory in which to capture stdout from each job. Setting this to +false+
  #               will cause clusterfuck to ignore job output, leaving it up to you to capture the results
  #               of each job. (DEFAULT: ./fragments)
  class Configuration
    # Holds the user-specified options. Again, you probably don't want to access this directly -- use the
    # getter/setter syntax instead.
    attr_reader :options
    
    # Create a new Configuration object with default options.
    def initialize
      @options = {
          "timeout" => 2,
          "max_fail" => 3,
          "verbose" => VERBOSE_CANCEL,
          "show_report" => true,
          "temp" => "./fragments",
        }
    end
    
    # You can get/set options as if they were attributes, i.e. +config.foo = "bar"+ will set the option +foo+ to "bar".
    def method_missing(key,args=nil)
      if args.nil?
        return @options[key.to_s]
      else
        key = key.to_s.gsub!("=","")
        @options[key] = args
      end
    end
    
    # Get a pretty-printed version of the currently set options
    def to_s
      @options.map { |pair| "#{pair[0]} = \"#{pair[1]}\""}.join(", ")
    end
    
    # Convert array of string commands to Job objects if necessary
    def jobify!
      @options["jobs"].map! do |job|
        if not job.is_a?(Job) # Ah-ha, make this string into a job
          short = job.downcase.gsub(/[^a-z]/,"")
          short = job[0..7] if short.size > 8 
          Job.new(short,job)
        else # Don't change anything...
          job
        end
      end
    end
  end
  
  # The primary means of interacting with Clusterfuck. Create a new 
  # Task, passing in a block that takes a Configuration object as a parameter (rake-style).
  # The constructor returns after all jobs have been completed.
  class Task
    # See Configuration for a list of recognized configuration options.
    def initialize(&custom)
      # Run configuration options specified in clusterfile
      config = Configuration.new
      custom.call(config)
      config.jobify!
      
      # Make output fragment directory
      `mkdir #{config.temp}` if config.temp and not File.exists?(config.temp)
      
      # Run all jobs
      machines = config.hosts.map { |name| Machine.new(name,config) }
      machines.each { |machine| machine.run }
      
      # Wait for jobs to terminate
      machines.each do |machine| 
        begin
          machine.thread.join
        rescue Timeout::Error
          STDERR.puts machine.to_s
        end
      end
      
      # Print a report, if requested
      if config.show_report
        puts " Machine\t| STARTED\t| COMPLETE\t| FAILED\t|"
        machines.each { |machine| puts machine.report }
      end
    end
  end
  
  # Represents a single machine (node) in our ad hoc cluster
  class Machine
    # The hostname of this machine
    attr_accessor :host
    # The global config options specified when the task was created
    attr_accessor :config
    # The thread represented this machine's ssh process
    attr_reader :thread
    # The number of jobs this machine has completed
    attr_reader :jobs_completed
    # The number of jobs this machine has attempted
    attr_reader :jobs_attempted
    # Was this machine dropped from the host list (too many failed jobs)?
    attr_reader :dropped

    # Create a new machine with the specified +host+ and +config+
    def initialize(host,config)
      self.host = host
      self.config = config
      
      @thread = nil
      @jobs_completed = 0
      @jobs_attempted = 0
      @dropped = false
    end
    
    # Open an SSH connection to this machine and process jobs until the global jobs queue is empty
    def run
      @thread = Thread.new do
        while config.jobs.size > 0
          job = config.jobs.shift
          if config.debug
            puts "#{DEBUG_WARN} #{self.host} starting job '#{job.short_name}'"
            puts "#{DEBUG_WARN}     #{job.command}"
            delay = rand*(DEBUG_INTERVAL[1]-DEBUG_INTERVAL[0])+DEBUG_INTERVAL[0]
            @jobs_attempted += 1
            sleep(delay)
            @jobs_completed += 1
          else
            begin
              @jobs_attempted += 1
              Net::SSH.start(self.host,config.username,:password => config.password,:timeout => config.timeout) do |ssh|
                puts "Starting job #{job.short_name} on #{self.host}" if config.verbose >= VERBOSE_ALL
                if config.temp
                  ssh.exec(job.command + " > #{Dir.getwd}/#{config.temp}/#{job.short_name}.#{self.host}")
                else
                  ssh.exec(job.command)
                end
                @jobs_completed += 1
              end
            rescue Timeout::Error
              puts "#{job.short_name} FAILED on #{self.host}, dropping it from the hostlist" if config.verbose >= VERBOSE_FAIL
              if not job.failed < config.max_fail
                config.jobs.push job
                job.failed += 1
              else
                puts "CANCELLING #{job.short_name}, too many failures (#{job.failed})" if config.verbose >= VERBOSE_CANCEL
              end
              @dropped = true
              break
            end
          end
        end
      end
    end
    
    # Get a one-line summary of this machine's performance
    def report
      tab = "\t"
      if self.host.size > 7
        tab = ""
      end
      "#{self.host}#{tab}\t| #{@jobs_attempted}\t\t| #{@jobs_completed}\t\t| #{@dropped ? 'YES' : 'no'}\t\t|"
    end
  end  
  
  # Represents an individual job to be run
  class Job
    # The short name of this job, used to name the temporary file it produces
    attr_accessor :short_name
    # The actual command to run to execute this job.
    attr_accessor :command
    # The number of times this job has been unsuccessfully attempted.
    attr_accessor :failed
    
    # Create a new job with the specified short and command
    def initialize(short_name,command)
      self.short_name = short_name
      self.command = command
      
      self.failed = 0
    end    
  end
end
