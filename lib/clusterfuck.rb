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

  # A configuration holds the various pieces of information Clusterfuck needs
  # to represent a task. 
  #
  # You probably won't need to instantiate a Configuration directly; one is created
  # when you create a new Task, and passed to the block it takes as a parameter. See Task
  # for more information.
  #
  # Possible configuration options include:
  # [timeout]     Number of seconds to wait before an SSH connection 'times out'
  # [max_fail]    Max number of times a failing job will be re-attempted on a new machine
  # [hosts]       Array of hostnames (or ip addresses) as Strings to use as nodes
  # [jobs]        Array of Job objects, one per job, which will be allocated to the +hosts+
  # [verbose]     Level of message reporting. One of +VERBOSE_CANCEL+,+VERBOSE_FAIL+, or +VERBOSE_ALL+
  # [username]    The SSH username to use to connect
  # [password]    The SSH password to use to connect
  # [show_report] Show a report after all jobs are complete that gives statistics for each machine.
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
          "show_report" => true
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
      
      # Make output fragment directory
      `mkdir #{config.temp}` if not File.exists?(config.temp)
      
      # Run all jobs
      machines = config.hosts.map { |name| Machine.new(name,config) }
      machines.each { |machine| machine.run }
      
      # Wait for jobs to terminate
      machines.each { |machine| machine.thread.join }
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

    # Create a new machine with the specified +host+ and +config+
    def initialize(host,config)
      self.host = host
      self.config = config
      
      @thread = nil
    end
    
    # Open an SSH connection to this machine and process jobs until the global jobs queue is empty
    def run
      @thread = Thread.new do
        while config.jobs.size > 0
          job = config.jobs.shift
          begin
            Net::SSH.start(self.host,config.username,:password => config.password,:timeout => config.timeout) do |ssh|
              puts "Starting job #{job.short_name} on #{self.host}" if config.verbose >= VERBOSE_ALL
              ssh.exec(job.command + " > #{Dir.getwd}/#{config.temp}/#{job.short_name}.#{self.host}")
            end
          rescue
            puts "#{job.short_name} FAILED on #{self.host}, dropping it from the hostlist" if config.verbose >= VERBOSE_FAIL
            if not job.failed < config.max_fail
              config.jobs.push job
              job.failed += 1
            else
              puts "CANCELLING #{job.short_name}, too many failures (#{job.failed})" if config.verbose >= VERBOSE_CANCEL
            end
            break
          end
        end
      end
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
