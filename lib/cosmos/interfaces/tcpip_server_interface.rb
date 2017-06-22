# encoding: ascii-8bit

# Copyright 2017 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'socket'
require 'thread' # For Mutex
require 'timeout' # For Timeout::Error
require 'cosmos/interfaces/stream_interface'
require 'cosmos/streams/tcpip_socket_stream'
require 'cosmos/config/config_parser'

module Cosmos

  # TCP/IP Server which can both read and write on a single port or two
  # independent ports. A listen thread is setup which waits for client
  # connections. For each connection to the read port, a thread is spawned that
  # calls the read method from the stream protocol. This data is then
  # available by calling the TcpipServer read method. For each connection to the
  # write port, a thread is spawned that calls the write method from the stream
  # protocol when data is send to the TcpipServer via the write method.
  class TcpipServerInterface < StreamInterface

    # Data class which stores the interface and associated information
    class InterfaceInfo
      attr_reader :interface, :hostname, :host_ip, :port
      def initialize(interface, hostname, host_ip, port)
        @interface = interface
        @hostname = hostname
        @host_ip = host_ip
        @port = port
      end
    end

    # Callback method to call when a new client connects to the write port.
    # This method will be called with the Interface as the only argument.
    attr_accessor :write_connection_callback
    # Callback method to call when a new client connects to the read port.
    # This method will be called with the Interface as the only argument.
    attr_accessor :read_connection_callback
    # @return [RawLoggerPair] RawLoggerPair instance or nil
    attr_accessor :raw_logger_pair
    # @return [String] The ip address to bind to.  Default to ANY (0.0.0.0)
    attr_accessor :listen_address
    # @return [boolean] Automatically send SYSTEM META on connect - Default false - Can be CMD/TLM
    attr_accessor :auto_system_meta

    # @param write_port [Integer] The server write port. Clients should connect
    #   and expect to receive data from this port.
    # @param read_port [Integer] The server read port. Clients should connect
    #   and expect to send data to this port.
    # @param write_timeout [Float|nil] The number of seconds to wait for the
    #   write to complete. Pass nil to block until the write is complete.
    # @param read_timeout [Float|nil] The number of seconds to wait for the
    #   read to complete. Pass nil to block until the read is complete.
    # @param stream_protocol_type [String] The name of the stream protocol to
    #   use for both the read and write ports. This name is combined with
    #   'StreamProtocol' to result in a COSMOS StreamProtocol class.
    # @param stream_protocol_args [Array] Arguments to pass to the StreamProtocol
    def initialize(write_port,
                   read_port,
                   write_timeout,
                   read_timeout,
                   stream_protocol_type = nil,
                   *stream_protocol_args)
      super(stream_protocol_type, stream_protocol_args)
      @write_port = ConfigParser.handle_nil(write_port)
      @write_port = Integer(write_port) if @write_port
      @read_port = ConfigParser.handle_nil(read_port)
      @read_port = Integer(read_port) if @read_port
      @write_timeout = ConfigParser.handle_nil(write_timeout)
      @write_timeout = @write_timeout.to_f if @write_timeout
      @read_timeout = ConfigParser.handle_nil(read_timeout)
      @read_timeout = @read_timeout.to_f if @read_timeout
      @listen_sockets = []
      @listen_pipes = []
      @listen_threads = []
      @read_threads = []
      @write_interfaces = []
      @read_interfaces = []
      @write_queue = nil
      @write_queue = Queue.new if @write_port
      @read_queue = nil
      @read_queue = Queue.new if @read_port
      @write_mutex = nil
      @write_mutex = Mutex.new if @write_port
      @write_condition_variable = nil
      @write_condition_variable = ConditionVariable.new if @write_port
      @write_connection_callback = nil
      @read_connection_callback = nil
      @raw_logger_pair = nil
      @raw_logging_enabled = false
      @connection_mutex = Mutex.new
      @listen_address = Socket::INADDR_ANY
      @auto_system_meta = false

      @read_allowed = false unless ConfigParser.handle_nil(read_port)
      @write_allowed = false unless ConfigParser.handle_nil(write_port)
      @write_raw_allowed = false unless ConfigParser.handle_nil(write_port)

      @connected = false
    end

    # Create the read and write port listen threads. Incoming connections will
    # spawn separate threads to process the reads and writes.
    def connect
      @cancel_threads = false
      @read_queue.clear if @read_queue
      if @write_port == @read_port # One socket
        start_listen_thread(@read_port, true, true)
      else
        start_listen_thread(@write_port, true, false) if @write_port
        start_listen_thread(@read_port, false, true) if @read_port
      end

      if @write_port
        @write_thread = Thread.new do
          begin
            loop do
              write_thread_body()
              break if @cancel_threads
            end
          rescue Exception => err
            shutdown_interfaces(@write_interfaces)
            Logger.instance.error("Tcpip server write thread unexpectedly died")
            Logger.instance.error(err.formatted)
          end
        end
      else
        @write_thread = nil
      end
      @connected = true
    end

    # @return [Boolean] Whether the server is listening for connections
    def connected?
      @connected
    end

    # Shutdowns the listener threads for both the read and write ports as well
    # as any client connections. As a part of shutting down client connections,
    # the {StreamProtocol#disconnect} method is called.
    def disconnect
      @cancel_threads = true
      @read_queue << nil if @read_queue
      @listen_pipes.each do |pipe|
        begin
          pipe.write('.')
        rescue Exception
          # Oh well
        end
      end
      @listen_pipes.clear

      # Shutdown listen thread(s)
      @listen_threads.each { |listen_thread| Cosmos.kill_thread(self, listen_thread) }
      @listen_threads.clear

      # Shutdown listen socket(s)
      @listen_sockets.each do |listen_socket|
        begin
          Cosmos.close_socket(listen_socket)
        rescue IOError
          # Ok may have been closed by the thread
        end
      end
      @listen_sockets.clear

      # This will unblock read threads
      shutdown_interfaces(@read_interfaces)

      @read_threads.each { |thread| Cosmos.kill_thread(self, thread) }
      @read_threads.clear
      if @write_thread
        Cosmos.kill_thread(self, @write_thread)
        @write_thread = nil
      end

      shutdown_interfaces(@write_interfaces)
      @connected = false
    end

    # Gracefully kill all the threads
    def graceful_kill
      # This method is just here to prevent warnings
    end

    # @return [Packet] Latest packet read from any of the connected clients.
    #   Note this method blocks until data is available.
    def read
      return nil unless @read_queue
      packet = @read_queue.pop
      return nil unless packet
      packet
    end

    # @param packet [Packet] Packet to write to all clients connected to the
    #   write port.
    def write(packet)
      return unless @write_queue
      @write_queue << packet
      @write_condition_variable.broadcast
    end

    # @param data [String] Data to write to all clients connected to the
    #   write port.
    def write_raw(data)
      return unless @write_queue
      packet = Packet.new(nil, nil)
      packet.buffer = data
      @write_queue << packet
      @write_condition_variable.broadcast
      return data
    end

    # @return [Integer] The number of packets waiting on the read queue
    def read_queue_size
      @read_queue ? @read_queue.size : 0
    end

    # @return [Integer] The number of packets waiting on the write queue
    def write_queue_size
      @write_queue ? @write_queue.size : 0
    end

    # @return [Integer] The number of connected clients
    def num_clients
      clients = []
      @write_interfaces.each do |interface|
        clients << [interface.host_ip, interface.port]
      end
      @read_interfaces.each do |interface|
        clients << [interface.host_ip, interface.port]
      end
      clients.uniq.length
    end

    # Start raw logging for this interface
    def start_raw_logging
      @raw_logging_enabled = true
      change_raw_logging(:start)
    end

    # Stop raw logging for this interface
    def stop_raw_logging
      @raw_logging_enabled = false
      change_raw_logging(:stop)
    end

    # Supported Options
    # LISTEN_ADDRESS - Ip address of the interface to accept connections on - Default: 0.0.0.0
    # AUTO_SYSTEM_META - Automatically send SYSTEM META on connect - Default false
    # (see Interface#set_option)
    def set_option(option_name, option_values)
      super(option_name, option_values)
      case option_name.upcase
      when 'LISTEN_ADDRESS'
        @listen_address = option_values[0]
      when 'AUTO_SYSTEM_META'
        @auto_system_meta = ConfigParser.handle_true_false(option_values[0])
      end
    end

    protected

    def shutdown_interfaces(interfaces)
      @connection_mutex.synchronize do
        interfaces.each do |interface|
          interface.interface.disconnect
          interface.interface.raw_logger_pair.stop if interface.interface.raw_logger_pair
        end
        interfaces.clear
      end
    end

    def change_raw_logging(method)
      if @raw_logger_pair
        @write_interfaces.each do |interface|
          interface.interface.raw_logger_pair.send(method) if interface.interface.raw_logger_pair
        end
        @read_interfaces.each do |interface|
          interface.interface.raw_logger_pair.send(method) if interface.interface.raw_logger_pair
        end
      end
    end

    def start_listen_thread(port, listen_write = false, listen_read = false)
      # Create a socket to accept connections from clients
      addr = Socket.pack_sockaddr_in(port, @listen_address)
      listen_socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
      listen_socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1) unless Kernel.is_windows?
      begin
        listen_socket.bind(addr)
      rescue Errno::EADDRINUSE
        raise "Error binding to port #{port}.\n" +
              "Either another application is using this port\n" +
              "or the operating system is being slow cleaning up.\n" +
              "Make sure all sockets/streams are closed in all applications,\n" +
              "wait 1 minute and try again."
      end

      listen_socket.listen(5)
      @listen_sockets << listen_socket
      @listen_threads << Thread.new do
        begin
          thread_reader, thread_writer = IO.pipe
          @listen_pipes << thread_writer
          loop do
            listen_thread_body(listen_socket, listen_write, listen_read, thread_reader)
            break if @cancel_threads
          end
        rescue => err
          Logger.instance.error("Tcpip server listen thread unexpectedly died")
          Logger.instance.error(err.formatted)
        end
      end
    end

    def listen_thread_body(listen_socket, listen_write, listen_read, thread_reader)
      begin
        socket, address = listen_socket.accept_nonblock
      rescue Errno::EAGAIN, Errno::ECONNABORTED, Errno::EINTR, Errno::EWOULDBLOCK
        read_ready, _ = IO.select([listen_socket, thread_reader])
        if read_ready && read_ready.include?(thread_reader)
          return
        else
          retry
        end
      end

      port, host_ip = Socket.unpack_sockaddr_in(address)
      hostname = ''
      hostname = Socket.lookup_hostname_from_ip(host_ip) if System.instance.use_dns
      if System.instance.acl
        addr = ["AF_INET", 10, "lc630", host_ip.to_s]
        if not System.instance.acl.allow_addr?(addr)
          # Reject connection
          Cosmos.close_socket(socket)
          Logger.instance.info "Tcpip server rejected connection from #{hostname}(#{host_ip}):#{port}"
          return
        end
      end

      # Configure TCP_NODELAY option
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

      # Accept Connection
      write_socket = nil
      read_socket = nil
      write_socket = socket if listen_write
      read_socket = socket if listen_read
      stream = TcpipSocketStream.new(write_socket, read_socket, @write_timeout, @read_timeout)

      interface = StreamInterface.new
      if @raw_logger_pair
        interface.raw_logger_pair = @raw_logger_pair.clone
        interface.raw_logger_pair.start if @raw_logging_enabled
      end
      @protocol_info.each do |protocol_class, protocol_args, read_write|
        interface.add_protocol(protocol_class, protocol_args, read_write)
      end
      interface.stream = stream
      interface.connect

      if listen_write
        if @auto_system_meta
          meta_packet = System.telemetry.packet('SYSTEM', 'META').clone
          interface.stream.write(meta_packet.buffer(false))
        end

        @write_connection_callback.call(interface) if @write_connection_callback
        @connection_mutex.synchronize do
          @write_interfaces << InterfaceInfo.new(interface, hostname, host_ip, port)
        end
      end
      if listen_read
        @read_connection_callback.call(interface) if @read_connection_callback
        @connection_mutex.synchronize do
          @read_interfaces << InterfaceInfo.new(interface, hostname, host_ip, port)
        end
        start_read_thread(@read_interfaces[-1])
      end
      Logger.instance.info "Tcpip server accepted connection from #{hostname}(#{host_ip}):#{port}"
    end

    def start_read_thread(interface)
      @read_threads << Thread.new do
        index_to_delete = nil
        begin
          begin
            read_thread_body(interface.interface)
          rescue Exception => err
            Logger.instance.error "Tcpip server read thread unexpectedly died"
            Logger.instance.error err.formatted
          end
          Logger.instance.info "Tcpip server lost read connection to #{interface.hostname}(#{interface.host_ip}):#{interface.port}"
          @read_threads.delete(Thread.current)

          index_to_delete = nil
          @connection_mutex.synchronize do
            begin
              index = 0
              @read_interfaces.each do |read_interface|
                if interface.interface == read_interface.interface
                  index_to_delete = index
                  read_interface.interface.disconnect
                  read_interface.interface.raw_logger_pair.stop if read_interface.interface.raw_logger_pair
                  break
                end
                index += 1
              end
            ensure
              if index_to_delete
                @read_interfaces.delete_at(index_to_delete)
              end
            end
          end
        rescue Exception => err
          Logger.instance.error "Tcpip server read thread unexpectedly died"
          Logger.instance.error err.formatted
        end
      end
    end

    def write_thread_body
      # Retrieve the next packet to be sent out to clients
      # Handles disconnected clients even when packets aren't flowing
      packet = nil

      loop do
        break if @cancel_threads
        begin
          packet = @write_queue.pop(true) # non_block to raise ThreadError
          break
        rescue ThreadError
          check_for_dead_clients()
        end
      end

      packet = write_thread_hook(packet)
      write_packet_to_clients(packet) if packet
    end

    def interface_disconnect(interface)
      Logger.instance.info "Tcpip server lost write connection to "\
        "#{interface.hostname}(#{interface.host_ip}):#{interface.port}"
      interface.interface.disconnect
      interface.interface.raw_logger_pair.stop if interface.interface.raw_logger_pair
    end

    def write_thread_hook(packet)
      packet # By default just return the packet
    end

    def read_thread_body(interface)
      loop do
        packet = interface.read
        return if !packet || @cancel_threads
        packet = read_thread_hook(packet) # Do work on received packet
        @read_queue << packet.clone
      end
    end

    # @return [Packet] Return the packet
    def read_thread_hook(packet)
      packet
    end

    def check_for_dead_clients
      indexes_to_delete = []
      index = 0

      @connection_mutex.synchronize do
        @write_interfaces.each do |interface|
          begin
            if (@write_port != @read_port)
              # Socket should return EWOULDBLOCK if it is still cleanly connected
              interface.interface.stream.write_socket.recvfrom_nonblock(10)
            elsif (!interface.interface.stream.write_socket.closed?)
              # Let read thread detect disconnect
              next
            end
            # Client has disconnected (or is invalidly sending data on the socket)
            Logger.instance.info "Tcpip server lost write connection to #{interface.hostname}(#{interface.host_ip}):#{interface.port}"
            interface.interface.disconnect
            interface.interface.raw_logger_pair.stop if interface.interface.raw_logger_pair
            indexes_to_delete.unshift(index) # Put later indexes at front of array
          rescue Errno::ECONNRESET, Errno::ECONNABORTED, IOError
            # Client has disconnected
            Logger.instance.info "Tcpip server lost write connection to #{interface.hostname}(#{interface.host_ip}):#{interface.port}"
            interface.interface.disconnect
            interface.interface.raw_logger_pair.stop if interface.interface.raw_logger_pair
            indexes_to_delete.unshift(index) # Put later indexes at front of array
          rescue Errno::EWOULDBLOCK
            # Client is still cleanly connected as far as we can tell without writing to the socket
          ensure
            index += 1
          end
        end

        # Delete any dead sockets
        indexes_to_delete.each do |index_to_delete|
          @write_interfaces.delete_at(index_to_delete)
        end
      end # connection_mutex.synchronize

      # Sleep until we receive a packet or for 100ms
      @write_mutex.synchronize do
        @write_condition_variable.wait(@write_mutex, 0.1)
      end
    end

    def write_packet_to_clients(packet)
      @connection_mutex.synchronize do
        # Send data to each client - On error drop the client
        indexes_to_delete = []
        index = 0
        @write_interfaces.each do |interface|
          need_disconnect = false
          begin
            interface.interface.write(packet)
          rescue Errno::EPIPE, Errno::ECONNABORTED, IOError, Errno::ECONNRESET
            # Client has normally disconnected
            need_disconnect = true
          rescue Exception => err
            if err.message != "Stream not connected for write_raw"
              Logger.instance.error "Error sending to client: #{err.class} #{err.message}"
            end
            need_disconnect = true
          end

          if need_disconnect
            Logger.instance.info "Tcpip server lost write connection to #{interface.hostname}(#{interface.host_ip}):#{interface.port}"
            interface.interface.disconnect
            interface.interface.raw_logger_pair.stop if interface.interface.raw_logger_pair
            indexes_to_delete.unshift(index) # Put later indexes at front of array
          end
          index += 1
        end

        # Delete any dead sockets
        indexes_to_delete.each do |index_to_delete|
          @write_interfaces.delete_at(index_to_delete)
        end
      end # connection_mutex.synchronize
    end
  end
end
