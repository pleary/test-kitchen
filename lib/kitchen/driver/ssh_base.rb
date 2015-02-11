# -*- encoding: utf-8 -*-
#
# Author:: Fletcher Nichol (<fnichol@nichol.ca>)
#
# Copyright (C) 2012, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
require 'pathname'
require 'rubygems'
require 'rubygems/package'
require 'rubygems/package/tar_writer'

module Kitchen

  module Driver

    # Base class for a driver that uses SSH to communication with an instance.
    # A subclass must implement the following methods:
    # * #create(state)
    # * #destroy(state)
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class SSHBase < Base

      default_config :sudo, true
      default_config :port, 22

      # (see Base#create)
      def create(state) # rubocop:disable Lint/UnusedMethodArgument
        raise ClientError, "#{self.class}#create must be implemented"
      end

      # (see Base#converge)
      def converge(state)
        provisioner = instance.provisioner
        provisioner.create_sandbox
        sandbox_dirs = Dir.glob("#{provisioner.sandbox_path}/*")

        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(provisioner.install_command, conn)
          run_remote(provisioner.init_command, conn)
          transfer_path(sandbox_dirs, provisioner[:root_path], conn)
          run_remote(provisioner.prepare_command, conn)
          run_remote(provisioner.run_command, conn)
        end
      ensure
        provisioner && provisioner.cleanup_sandbox
      end

      # (see Base#setup)
      def setup(state)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(busser.setup_cmd, conn)
        end
      end

      # (see Base#verify)
      def verify(state)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(busser.sync_cmd, conn)
          run_remote(busser.run_cmd, conn)
        end
      end

      # (see Base#destroy)
      def destroy(state) # rubocop:disable Lint/UnusedMethodArgument
        raise ClientError, "#{self.class}#destroy must be implemented"
      end

      # (see Base#login_command)
      def login_command(state)
        SSH.new(*build_ssh_args(state)).login_command
      end

      # Executes an arbitrary command on an instance over an SSH connection.
      #
      # @param state [Hash] mutable instance and driver state
      # @param command [String] the command to be executed
      # @raise [ActionFailed] if the command could not be successfully completed
      def remote_command(state, command)
        Kitchen::SSH.new(*build_ssh_args(state)) do |conn|
          run_remote(command, conn)
        end
      end

      # **(Deprecated)** Executes a remote command over SSH.
      #
      # @param ssh_args [Array] ssh arguments
      # @param command [String] remote command to invoke
      # @deprecated This method should no longer be called directly and exists
      #   to support very old drivers. This will be removed in the future.
      def ssh(ssh_args, command)
        Kitchen::SSH.new(*ssh_args) do |conn|
          run_remote(command, conn)
        end
      end

      private

      # Builds arguments for constructing a `Kitchen::SSH` instance.
      #
      # @param state [Hash] state hash
      # @return [Array] SSH constructor arguments
      # @api private
      def build_ssh_args(state)
        combined = config.to_hash.merge(state)

        opts = Hash.new
        opts[:user_known_hosts_file] = "/dev/null"
        opts[:paranoid] = false
        opts[:keys_only] = true if combined[:ssh_key]
        opts[:password] = combined[:password] if combined[:password]
        opts[:forward_agent] = combined[:forward_agent] if combined.key? :forward_agent
        opts[:port] = combined[:port] if combined[:port]
        opts[:keys] = Array(combined[:ssh_key]) if combined[:ssh_key]
        opts[:logger] = logger

        [combined[:hostname], combined[:username], opts]
      end

      # Adds http and https proxy environment variables to a command, if set
      # in configuration data.
      #
      # @param cmd [String] command string
      # @return [String] command string
      # @api private
      def env_cmd(cmd)
        env = "env"
        env << " http_proxy=#{config[:http_proxy]}" if config[:http_proxy]
        env << " https_proxy=#{config[:https_proxy]}" if config[:https_proxy]

        env == "env" ? cmd : "#{env} #{cmd}"
      end

      # Executes a remote command over SSH.
      #
      # @param command [String] remove command to run
      # @param connection [Kitchen::SSH] an SSH connection
      # @raise [ActionFailed] if an exception occurs
      # @api private
      def run_remote(command, connection)
        return if command.nil?

        connection.exec(env_cmd(command))
      rescue SSHFailed, Net::SSH::Exception => ex
        raise ActionFailed, ex.message
      end

      # Transfers one or more local paths over SSH.
      #
      # @param locals [Array<String>] array of local paths
      # @param remote [String] remote destination path
      # @param connection [Kitchen::SSH] an SSH connection
      # @raise [ActionFailed] if an exception occurs
      # @api private
      def transfer_path(locals, remote, connection)
        return if locals.nil? || Array(locals).empty?

        info('Compress files before transferring')
        pack(locals) do |file|
          connection.upload_path!(file.path, remote)
          filename = File.basename(file.path)
          info("Transferring files to #{instance.to_str}")
          run_remote("cd #{remote} && tar xvfz #{filename} > /dev/null && rm #{filename}", connection)
        end
        debug('Transfer complete')
      rescue SSHFailed, Net::SSH::Exception => ex
        raise ActionFailed, ex.message
      end

      # Blocks until a TCP socket is available where a remote SSH server
      # should be listening.
      #
      # @param hostname [String] remote SSH server host
      # @param username [String] SSH username (default: `nil`)
      # @param options [Hash] configuration hash (default: `{}`)
      # @api private
      def wait_for_sshd(hostname, username = nil, options = {})
        SSH.new(hostname, username, { :logger => logger }.merge(options)).wait
      end

      def pack(locals)
        tar_archive = Tempfile.new(['sandbox', '.tar'])
        Gem::Package::TarWriter.new(tar_archive) do |tar|
          locals.each do |path|
            base_path = Pathname.new(path).parent
            files = File.file?(path) ? Array(path) : Dir.glob("#{path}/**/*")
            files.each do |file|
              mode = File.stat(file).mode
              relative_path = Pathname.new(file).relative_path_from(base_path)
              if File.directory?(file)
                tar.mkdir(relative_path.to_s, mode)
              else
                tar.add_file(relative_path.to_s, mode) do |tf|
                  File.open(file, 'rb') { |f| tf.write f.read }
                end
              end
            end
          end
        end
        tar_archive.rewind
        tgz_archive = Tempfile.new(['sandbox', '.tar.gz'])
        gzip = Zlib::GzipWriter.new(tgz_archive)
        gzip.write tar_archive.read
        gzip.close
        yield(tgz_archive)
      ensure
        tar_archive.unlink if tar_archive
        tgz_archive.unlink if tgz_archive
      end
    end
  end
end
