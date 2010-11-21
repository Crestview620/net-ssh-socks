require 'net/ssh'

module Net
  module SSH
    class Socks
      VERSION = "0.0.1"

      SOCKS_VERSION  = 5
      METHOD_NO_AUTH = 0
      CMD_CONNECT    = 1
      REP_SUCCESS    = 0
      RESERVED       = 0
      ATYP_IPV4      = 1
      ATYP_DOMAIN    = 3
      ATYP_IPV6      = 4

      # client is an open socket
      def initialize(client)
        @client = client
      end

      # Communicates with a client application as described by the SOCKS 5
      # specification: http://tools.ietf.org/html/rfc1928 and
      # http://en.wikipedia.org/wiki/SOCKS
      #
      # returns the host and port requested by the client
      def client_handshake
        version, nmethods, *methods = @client.recv(8).unpack("C*")

        if methods.include?(METHOD_NO_AUTH)
          packet = [SOCKS_VERSION, METHOD_NO_AUTH].pack("C*")
          @client.send packet, 0
        else
          @client.close
          raise 'Unsupported authentication method. Only "No Authentication" is supported'
        end

        version, command, reserved, address_type, *destination = @client.recv(256).unpack("C*")

        packet = ([SOCKS_VERSION, REP_SUCCESS, RESERVED, address_type] + destination).pack("C*")
        @client.send packet, 0

        remote_host, remote_port = case address_type
        when ATYP_IPV4
          host = destination[0..-3].join('.')
          port = destination[-2..-1].pack('C*').unpack('n')
          [host, port]
        when ATYP_DOMAIN
          @client.close
          raise 'Unsupported address type. Only "IPv4" is supported'
        when ATYP_IPV6
          @client.close
          raise 'Unsupported address type. Only "IPv4" is supported'
        end

        [remote_host, remote_port]
      end

    end
  end
end

class Net::SSH::Service::Forward
  # Starts listening for connections on the local host, and forwards them
  # to the specified remote host/port via the SSH connection. This method
  # accepts either one or two arguments. When two arguments are given,
  # they are:
  #
  # * the local address to bind to
  # * the local port to listen on
  #
  # If one argument is given, it is as if the local bind address is
  # "127.0.0.1", and the rest are applied as above.
  #
  #   ssh.forward.socks(8080)
  #   ssh.forward.socks("0.0.0.0", 8080)
  def socks(*args)
    if args.length < 1 || args.length > 2
      raise ArgumentError, "expected 1 or 2 parameters, got #{args.length}"
    end

    bind_address = "127.0.0.1"
    bind_address = args.shift if args.first.is_a?(String) && args.first =~ /\D/
    local_port   = args.shift.to_i

    socket = TCPServer.new(bind_address, local_port)
    session.listen_to(socket) do |socket|
      client = socket.accept

      socks = Net::SSH::Socks.new(client)
      remote_host, remote_port = socks.client_handshake

      channel = session.open_channel("direct-tcpip", :string, remote_host, :long, remote_port, :string, bind_address, :long, local_port) do |channel|
        channel.info { "direct channel established" }
        prepare_client(client, channel, :local)
      end

      channel.on_open_failed do |ch, code, description|
        channel.error { "could not establish direct channel: #{description} (#{code})" }
        client.close
      end
    end
  end
end
