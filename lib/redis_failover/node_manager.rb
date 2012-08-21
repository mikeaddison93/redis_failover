module RedisFailover
  # NodeManager manages a list of redis nodes. Upon startup, the NodeManager
  # will discover the current redis master and slaves. Each redis node is
  # monitored by a NodeWatcher instance. The NodeWatchers periodically
  # report the current state of the redis node it's watching to the
  # NodeManager via an asynchronous queue. The NodeManager processes the
  # state reports and reacts appropriately by handling stale/dead nodes,
  # and promoting a new redis master if it sees fit to do so.
  class NodeManager
    include Util

    # Number of seconds to wait before retrying bootstrap process.
    TIMEOUT = 5
    # Default client failover ACK timeout.
    DEFAULT_ACK_TIMEOUT = 10

    # Creates a new instance.
    #
    # @param [Hash] options the options used to initialize the manager
    # @option options [String] :zkservers comma-separated ZK host:port pairs
    # @option options [String] :znode_path znode path override for redis nodes
    # @option options [String] :password password for redis nodes
    # @option options [Array<String>] :nodes the nodes to manage
    # @option options [String] :max_failures the max failures for a node
    def initialize(options)
      logger.info("Redis Node Manager v#{VERSION} starting (#{RUBY_DESCRIPTION})")
      @options = options
      @znode = @options[:znode_path] || DEFAULT_ZNODE_PATH
      @failover_ack_timeout = @options[:failover_ack_timeout] || DEFAULT_ACK_TIMEOUT
      @manual_znode = ManualFailover::ZNODE_PATH
      @mutex = Mutex.new

      # Name for the znode that handles exclusive locking between multiple
      # Node Manager processes. Whoever holds the lock will be considered
      # the "master" Node Manager, and will be responsible for monitoring
      # the redis nodes. When a Node Manager that holds the lock disappears
      # or fails, another Node Manager process will grab the lock and
      # become the
      @lock_path = "#{@znode}_lock".freeze
    end

    # Starts the node manager.
    #
    # @note This method does not return until the manager terminates.
    def start
      @queue = Queue.new
      @leader = false
      setup_zk
      logger.info('Waiting to become master Node Manager ...')
      @zk.with_lock(@lock_path) do
        @leader = true
        logger.info('Acquired master Node Manager lock')
        discover_nodes
        initialize_path
        spawn_watchers
        handle_state_reports
      end
    rescue ZK::Exceptions::InterruptedSession, ZKDisconnectedError => ex
      logger.error("ZK error while attempting to manage nodes: #{ex.inspect}")
      logger.error(ex.backtrace.join("\n"))
      shutdown
      sleep(TIMEOUT)
      retry
    end

    # Notifies the manager of a state change. Used primarily by
    # {RedisFailover::NodeWatcher} to inform the manager of watched node states.
    #
    # @param [Node] node the node
    # @param [Symbol] state the state
    def notify_state(node, state)
      @queue << [node, state]
    end

    # Performs a graceful shutdown of the manager.
    def shutdown
      @queue.clear
      @queue << nil
      @watchers.each(&:shutdown) if @watchers
      @zk.close! if @zk
    end

    private

    # Configures the ZooKeeper client.
    def setup_zk
      @zk.close! if @zk
      @zk = ZK.new("#{@options[:zkservers]}#{@options[:chroot] || ''}")
      @zk.on_expired_session { notify_state(:zk_disconnected, nil) }

      @zk.register(@manual_znode) do |event|
        @mutex.synchronize do
          begin
            if event.node_created? || event.node_changed?
              schedule_manual_failover
            end
          rescue => ex
            logger.error("Error scheduling a manual failover: #{ex.inspect}")
            logger.error(ex.backtrace.join("\n"))
          ensure
            @zk.stat(@manual_znode, :watch => true)
          end
        end
      end

      @zk.on_connected { @zk.stat(@manual_znode, :watch => true) }
      @zk.stat(@manual_znode, :watch => true)
    end

    # Handles periodic state reports from {RedisFailover::NodeWatcher} instances.
    def handle_state_reports
      while state_report = @queue.pop
        begin
          node, state = state_report
          case state
          when :unavailable     then handle_unavailable(node)
          when :available       then handle_available(node)
          when :syncing         then handle_syncing(node)
          when :manual_failover then handle_manual_failover(node)
          when :zk_disconnected then raise ZKDisconnectedError
          else raise InvalidNodeStateError.new(node, state)
          end

          # flush current state
          write_state
        rescue ZK::Exceptions::InterruptedSession, ZKDisconnectedError
          # fail hard if this is a ZK connection-related error
          raise
        rescue => ex
          logger.error("Error handling #{state_report.inspect}: #{ex.inspect}")
          logger.error(ex.backtrace.join("\n"))
        end
      end
    end

    # Handles an unavailable node.
    #
    # @param [Node] node the unavailable node
    def handle_unavailable(node)
      # no-op if we already know about this node
      return if @unavailable.include?(node)
      logger.info("Handling unavailable node: #{node}")

      @unavailable << node
      # find a new master if this node was a master
      if node == @master
        logger.info("Demoting currently unavailable master #{node}.")
        promote_new_master
      else
        @slaves.delete(node)
      end
    end

    # Handles an available node.
    #
    # @param [Node] node the available node
    def handle_available(node)
      reconcile(node)

      # no-op if we already know about this node
      return if @master == node || @slaves.include?(node)
      logger.info("Handling available node: #{node}")

      if @master
        # master already exists, make a slave
        node.make_slave!(@master)
        @slaves << node
      else
        # no master exists, make this the new master
        promote_new_master(node)
      end

      @unavailable.delete(node)
    end

    # Handles a node that is currently syncing.
    #
    # @param [Node] node the syncing node
    def handle_syncing(node)
      reconcile(node)

      if node.syncing_with_master? && node.prohibits_stale_reads?
        logger.info("Node #{node} not ready yet, still syncing with master.")
        force_unavailable_slave(node)
        return
      end

      # otherwise, we can use this node
      handle_available(node)
    end

    # Handles a manual failover request to the given node.
    #
    # @param [Node] node the candidate node for failover
    def handle_manual_failover(node)
      # no-op if node to be failed over is already master
      return if @master == node
      logger.info("Handling manual failover")

      # make current master a slave, and promote new master
      @slaves << @master
      @slaves.delete(node)
      promote_new_master(node)
    end

    # Promotes a new master.
    #
    # @param [Node] node the optional node to promote
    # @note if no node is specified, a random slave will be used
    def promote_new_master(node = nil)
      clients_lock = Mutex.new
      presence_group = ZK::Group.new(@zk, CLIENT_PRESENCE_GROUP)
      presence_group.create

      ack_group = ZK::Group.new(@zk, CLIENT_FAILOVER_ACK_GROUP)
      ack_group.create

      clients = presence_group.member_names
      delete_path

      # At this point the path is deleted. We only care about clients that
      # were previously known but have now left. We don't care about new
      # clients that appear, because we've already deleted the znode and
      # they will automatically see the new master once we write out the
      # new config.
      presence_group.on_membership_change do |old_members, current_members|
        clients_lock.synchronize do
          clients -= diff(clients, current_members)
        end
      end

      # Wait up to N seconds for all clients to ACK for failover.
      deadline = Time.now + @failover_ack_timeout
      condition = lambda do
        clients_lock.synchronize do
          ack_group.member_names.size >= clients.size
        end
      end
      if sleep_until(deadline, &condition)
        logger.info('Received failover ACK from all clients')
      else
        logger.info("Failed to receive failover ACK from all clients " +
                    "after #{@failover_ack_timeout}s")
      end

      logger.info('Attempting failover to a new master.')
      @master = nil

      # make a specific node or slave the new master
      candidate = node || @slaves.pop
      unless candidate
        logger.error('Failed to promote a new master, no candidate available.')
        return
      end

      redirect_slaves_to(candidate)
      candidate.make_master!
      @master = candidate

      create_path
      write_state
      logger.info("Successfully promoted #{candidate} to master.")
    end

    # Discovers the current master and slave nodes.
    def discover_nodes
      @unavailable = []
      nodes = @options[:nodes].map { |opts| Node.new(opts) }.uniq
      @master = find_master(nodes)
      @slaves = nodes - [@master]
      logger.info("Managing master (#{@master}) and slaves" +
        " (#{@slaves.map(&:to_s).join(', ')})")

      # ensure that slaves are correctly pointing to this master
      redirect_slaves_to(@master) if @master
    end

    # Spawns the {RedisFailover::NodeWatcher} instances for each managed node.
    def spawn_watchers
      @watchers = [@master, @slaves, @unavailable].flatten.map do |node|
        NodeWatcher.new(self, node, @options[:max_failures] || 3)
      end
      @watchers.each(&:watch)
    end

    # Searches for the master node.
    #
    # @param [Array<Node>] nodes the nodes to search
    # @return [Node] the found master node, nil if not found
    def find_master(nodes)
      nodes.find do |node|
        begin
          node.master?
        rescue NodeUnavailableError
          false
        end
      end
    end

    # Redirects all slaves to the specified node.
    #
    # @param [Node] node the node to which slaves are redirected
    def redirect_slaves_to(node)
      @slaves.dup.each do |slave|
        begin
          slave.make_slave!(node)
        rescue NodeUnavailableError
          logger.info("Failed to redirect unreachable slave #{slave} to #{node}")
          force_unavailable_slave(slave)
        end
      end
    end

    # Forces a slave to be marked as unavailable.
    #
    # @param [Node] node the node to force as unavailable
    def force_unavailable_slave(node)
      @slaves.delete(node)
      @unavailable << node unless @unavailable.include?(node)
    end

    # It's possible that a newly available node may have been restarted
    # and completely lost its dynamically set run-time role by the node
    # manager. This method ensures that the node resumes its role as
    # determined by the manager.
    #
    # @param [Node] node the node to reconcile
    def reconcile(node)
      return if @master == node && node.master?
      return if @master && node.slave_of?(@master)

      logger.info("Reconciling node #{node}")
      if @master == node && !node.master?
        # we think the node is a master, but the node doesn't
        node.make_master!
        return
      end

      # verify that node is a slave for the current master
      if @master && !node.slave_of?(@master)
        node.make_slave!(@master)
      end
    end

    # @return [Hash] the set of current nodes grouped by category
    def current_nodes
      {
        :master => @master ? @master.to_s : nil,
        :slaves => @slaves.map(&:to_s),
        :unavailable => @unavailable.map(&:to_s)
      }
    end

    # Deletes the znode path containing the redis nodes.
    def delete_path
      @zk.delete(@znode)
      logger.info("Deleted ZooKeeper node #{@znode}")
    rescue ZK::Exceptions::NoNode => ex
      logger.info("Tried to delete missing znode: #{ex.inspect}")
    end

    # Creates the znode path containing the redis nodes.
    def create_path
      unless @zk.exists?(@znode)
        @zk.create(@znode, encode(current_nodes))
        logger.info("Created ZooKeeper node #{@znode}")
      end
    rescue ZK::Exceptions::NodeExists
      # best effort
    end

    # Initializes the znode path containing the redis nodes.
    def initialize_path
      create_path
      write_state
    end

    # Writes the current redis nodes state to the znode path.
    def write_state
      create_path
      @zk.set(@znode, encode(current_nodes))
    end

    # Schedules a manual failover to a redis node.
    def schedule_manual_failover
      return unless @leader
      new_master = @zk.get(@manual_znode, :watch => true).first
      return unless new_master && new_master.size > 0
      logger.info("Received manual failover request for: #{new_master}")
      logger.info("Current nodes: #{current_nodes.inspect}")

      node = if new_master == ManualFailover::ANY_SLAVE
        @slaves.shuffle.first
      else
        host, port = new_master.split(':', 2)
        Node.new(:host => host, :port => port, :password => @options[:password])
      end

      if node
        notify_state(node, :manual_failover)
      else
        logger.error('Failed to perform manual failover, no candidate found.')
      end
    end
  end
end
