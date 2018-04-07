# require 'rubocop'
require 'thread'
require 'set'

module Solargraph
  module LanguageServer
    # The language server protocol's data provider. Hosts are responsible for
    # querying the library and processing messages.
    #
    class Host
      include Solargraph::LanguageServer::UriHelpers

      # @return [Solargraph::Library]
      attr_reader :library

      def initialize
        @change_semaphore = Mutex.new
        @buffer_semaphore = Mutex.new
        @change_queue = []
        @diagnostics_queue = []
        @cancel = []
        @buffer = ''
        @stopped = false
        @library = nil # @todo How to initialize the library
        start_change_thread
        start_diagnostics_thread
      end

      # @param update [Hash]
      def configure update
        options.merge! update
      end

      # @return [Hash]
      def options
        @options ||= {}
      end

      def cancel id
        @cancel.push id
      end

      def cancel? id
        @cancel.include? id
      end

      def clear id
        @cancel.delete id
      end

      def start request
        message = Message.select(request['method']).new(self, request)
        begin
          message.process
        rescue Exception => e
          STDERR.puts e.message
          STDERR.puts e.backtrace
          message.set_error Solargraph::LanguageServer::ErrorCodes::INTERNAL_ERROR, e.message
        end
        message
      end

      def create uri
        filename = uri_to_file(uri)
        library.create filename, File.read(filename)
      end

      def delete uri
        filename = uri_to_file(uri)
        library.delete filename
      end

      def open uri, text, version
        library.open uri_to_file(uri), text, version
        @change_semaphore.synchronize { @diagnostics_queue.push uri }
      end

      def change params
        @change_semaphore.synchronize do
          if unsafe_changing? params['textDocument']['uri']
            @change_queue.push params
          else
            source = library.checkout(uri_to_file(params['textDocument']['uri']))
            @change_queue.push params
            if params['textDocument']['version'] == source.version + params['contentChanges'].length
              updater = generate_updater(params)
              library.synchronize updater
              library.refresh
              @change_queue.pop
              @diagnostics_queue.push params['textDocument']['uri']
            end
          end
        end
      end

      def queue message
        @buffer_semaphore.synchronize do
          @buffer += message
        end
      end

      def flush
        tmp = nil
        @buffer_semaphore.synchronize do
          tmp = @buffer.clone
          @buffer.clear
        end
        tmp
      end

      # @param directory [String]
      def prepare directory
        path = nil
        path = normalize_separators(directory) unless directory.nil?
        @change_semaphore.synchronize do
          @library = Solargraph::Library.load(path)
        end
      end

      def send_notification method, params
        response = {
          jsonrpc: "2.0",
          method: method,
          params: params
        }
        json = response.to_json
        envelope = "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
        queue envelope
      end

      def changing? file_uri
        result = false
        @change_semaphore.synchronize do
          result = unsafe_changing?(file_uri)
        end
        result
      end

      def stop
        @stopped = true
      end

      def stopped?
        @stopped
      end

      def locate_pin params
        pin = nil
        @change_semaphore.synchronize do
          pin = library.locate_pin(params['data']['location']) unless params['data']['location'].nil?
          # @todo Improve pin location
          if pin.nil? or pin.path != params['data']['path']
            pin = library.path_pins(params['data']['path']).first
          end
        end
        pin
      end

      def read_text uri
        filename = uri_to_file(uri)
        library.read_text(filename)
      end

      def completions_at filename, line, column
        results = nil
        @change_semaphore.synchronize do
          results = library.completions_at filename, line, column
        end
        results
      end

      # @return [Array<Solargraph::Pin::Base>]
      def definitions_at filename, line, column
        results = nil
        @change_semaphore.synchronize do
          results = library.definitions_at(filename, line, column)
        end
        results
      end

      def signatures_at filename, line, column
        results = nil
        @change_semaphore.synchronize do
          results = library.signatures_at(filename, line, column)
        end
        results
      end

      private

      def unsafe_changing? file_uri
        @change_queue.any?{|change| change['textDocument']['uri'] == file_uri}
      end

      def start_change_thread
        Thread.new do
          until stopped?
            @change_semaphore.synchronize do
              changed = false
              begin
                @change_queue.delete_if do |change|
                  filename = uri_to_file(change['textDocument']['uri'])
                  source = library.checkout(filename)
                  if change['textDocument']['version'] == source.version + change['contentChanges'].length
                    updater = generate_updater(params)
                    library.synchronize updater
                    @diagnostics_queue.push change['textDocument']['uri']
                    changed = true
                    next true
                  elsif change['textDocument']['version'] == source.version + 1 #and change['contentChanges'].length == 0
                    # HACK: This condition fixes the fact that formatting
                    # increments the version by one regardless of the number
                    # of changes
                    updater = generate_updater(params)
                    library.synchronize updater
                    @diagnostics_queue.push change['textDocument']['uri']
                    changed = true
                    next true
                  elsif change['textDocument']['version'] <= source.version
                    # @todo Is deleting outdated changes correct behavior?
                    STDERR.puts "Deleting stale change"
                    @diagnostics_queue.push change['textDocument']['uri']
                    changed = true
                    next true
                  else
                    # @todo Change is out of order. Save it for later
                    STDERR.puts "Kept in queue: #{change['textDocument']['uri']} from #{source.version} to #{change['textDocument']['version']}"
                    next false
                  end
                end
                STDERR.puts "Refreshing library due to step changes" if changed
                library.refresh if changed
                STDERR.puts "#{@change_queue.length} pending" unless @change_queue.empty?
              rescue Exception => e
                STDERR.puts e.message
                STDERR.puts e.backtrace
              end
            end
            sleep 0.1
          end
          STDERR.puts "Beauty school dropout!"
        end
      end

      def start_diagnostics_thread
        Thread.new do
          diagnoser = Diagnostics::Rubocop.new
          until stopped?
            sleep 0.1
            if options['diagnostics'] != 'rubocop'
              @change_semaphore.synchronize { @diagnostics_queue.clear }
              sleep 1
              next
            end
            begin
              current = nil
              already_changing = nil
              @change_semaphore.synchronize do
                current = @diagnostics_queue.shift
                break if current.nil?
                already_changing = (unsafe_changing?(current) or @diagnostics_queue.include?(current))
              end
              next if current.nil? or already_changing
              filename = uri_to_file(current)
              text = library.read_text(filename)
              results = diagnoser.diagnose text, filename
              @change_semaphore.synchronize do
                already_changing = (unsafe_changing?(current) or @diagnostics_queue.include?(current))
                # publish_diagnostics current, resp unless already_changing
                unless already_changing
                  send_notification "textDocument/publishDiagnostics", {
                    uri: current,
                    diagnostics: results
                  }
                end
              end
            rescue Exception => e
              STDERR.puts e.message
              STDERR.puts e.backtrace
            end
          end
        end
      end

      def normalize_separators path
        return path if File::ALT_SEPARATOR.nil?
        path.gsub(File::ALT_SEPARATOR, File::SEPARATOR)
      end

      def generate_updater params
        changes = []
        params['contentChanges'].each do |chng|
          changes.push Solargraph::Source::Change.new(
            (chng['range'].nil? ? 
              nil : 
              Solargraph::Source::Range.from_to(chng['range']['start']['line'], chng['range']['start']['character'], chng['range']['end']['line'], chng['range']['end']['character'])
            ),
            chng['text']
          )
        end
        Solargraph::Source::Updater.new(
          uri_to_file(params['textDocument']['uri']),
          params['textDocument']['version'],
          changes
        )
      end
    end
  end
end