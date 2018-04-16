module Solargraph
  # A library handles coordination between a Workspace and an ApiMap.
  #
  class Library

    # @param workspace [Solargraph::Workspace]
    def initialize workspace = Solargraph::Workspace.new(nil)
      @workspace = workspace
      api_map
    end

    # Open a file in the library. Opening a file will make it available for
    # checkout and merge it into the workspace if applicable.
    #
    # @param filename [String]
    # @param text [String]
    # @param version [Integer]
    def open filename, text, version
      source = Solargraph::Source.load_string(text, filename)
      source.version = version
      source_hash[filename] = source
      workspace.merge source
      api_map.refresh
    end

    # True if the specified file is currently open in the workspace.
    #
    # @param filename [String]
    # @return [Boolean]
    def open? filename
      source_hash.has_key? filename
    end

    # Create a file source to be added to the workspace. The source is ignored
    # if the workspace is not configured to include the file.
    #
    # @param filename [String]
    # @param text [String] The contents of the file
    # @return [Boolean] True if the file was added to the workspace.
    def create filename, text
      return false unless workspace.would_merge?(filename)
      source = Solargraph::Source.load_string(text, filename)
      workspace.merge(source)
      api_map.refresh
      true
    end

    def create_from_disk filename
      return if File.directory?(filename) or !File.exist?(filename)
      return unless workspace.would_merge?(filename)
      source = Solargraph::Source.load_string(File.read(filename), filename)
      workspace.merge(source)
      api_map.refresh
    end

    # Delete a file from the library. Deleting a file will make it unavailable
    # for checkout and optionally remove it from the workspace unless the
    # workspace configuration determines that it should still exist.
    #
    # @param filename [String]
    def delete filename
      source = source_hash[filename]
      return if source.nil?
      source_hash.delete filename
      workspace.remove source
      api_map.refresh
    end

    # Close a file in the library. Closing a file will make it unavailable for
    # checkout although it may still exist in the workspace.
    #
    # @param filename [String]
    def close filename
      source_hash.delete filename
      if workspace.has_file?(filename)
        source = Solargraph::Source.load(filename)
        workspace.merge source
      end
    end

    def overwrite filename, version
      source = source_hash[filename]
      return if source.nil?
      STDERR.puts "Save out of sync for #{filename}" if source.version > version
      open filename, File.read(filename), version
    end

    # Get completion suggestions at the specified file and location.
    #
    # @param filename [String] The file to analyze
    # @param line [Integer] The zero-based line number
    # @param column [Integer] The zero-based column number
    # @return [ApiMap::Completion]
    def completions_at filename, line, column
      source = read(filename)
      api_map.virtualize source
      fragment = source.fragment_at(line, column)
      api_map.complete(fragment)
    end

    # Get definition suggestions for the expression at the specified file and
    # location.
    #
    # @param filename [String] The file to analyze
    # @param line [Integer] The zero-based line number
    # @param column [Integer] The zero-based column number
    # @return [Array<Solargraph::Pin::Base>]
    def definitions_at filename, line, column
      source = read(filename)
      api_map.virtualize source
      fragment = source.fragment_at(line, column)
      api_map.define(fragment)
    end

    # Get signature suggestions for the method at the specified file and
    # location.
    #
    # @param filename [String] The file to analyze
    # @param line [Integer] The zero-based line number
    # @param column [Integer] The zero-based column number
    # @return [Array<Solargraph::Pin::Base>]
    def signatures_at filename, line, column
      source = read(filename)
      api_map.virtualize source
      fragment = source.fragment_at(line, column)
      api_map.signify(fragment)
    end

    # Get the pin at the specified location or nil if the pin does not exist.
    #
    # @return [Solargraph::Pin::Base]
    def locate_pin location
      api_map.locate_pin location
    end

    # Get an array of pins that match a path.
    #
    # @param path [String]
    # @return [Array<Solargraph::Pin::Base>]
    def get_path_pins path
      api_map.get_path_suggestions(path)
    end

    # Check a file out of the library. If the file is not part of the
    # workspace, the ApiMap will virtualize it for mapping purposes. If
    # filename is nil, any source currently checked out of the library
    # will be removed from the ApiMap. Only one file can be checked out
    # (virtualized) at a time.
    #
    # @raise [FileNotFoundError] if the file is not in the library.
    #
    # @param filename [String]
    # @return [Source]
    def checkout filename
      if filename.nil?
        api_map.virtualize nil
        nil
      else
        read filename
      end
    end

    def refresh force = false
      api_map.refresh force
    end

    def document query
      api_map.document query
    end

    def search query
      api_map.search query
    end

    def query_symbols query
      api_map.query_symbols query
    end

    def file_symbols filename
      read(filename).all_symbols
    end

    def path_pins path
      api_map.get_path_suggestions(path)
    end

    def synchronize updater
      source = read(updater.filename)
      source.synchronize updater
    end

    # Get the current text of a file in the library.
    #
    # @param filename [String]
    # @return [String]
    def read_text filename
      source = read(filename)
      source.code
    end

    def diagnose filename
      result = []
      source = read(filename)
      refs = {}
      source.required.each do |ref|
        refs[ref.name] = ref
      end
      api_map.yard_map.unresolved_requires.each do |r|
        if refs.has_key?(r)
          result.push(
            range: refs[r].location.range.to_hash,
            # 1 = Error, 2 = Warning, 3 = Information, 4 = Hint
            severity: Diagnostics::Severities::WARNING,
            source: 'Solargraph',
            message: "Required path #{r} could not be resolved."
          )
        end
      end
      result
    end

    # Create a library from a directory.
    #
    # @param directory [String] The path to be used for the workspace
    # @return [Solargraph::Library]
    def self.load directory
      Solargraph::Library.new(Solargraph::Workspace.new(directory))
    end

    private

    # @return [Hash<String, Solargraph::Source>]
    def source_hash
      @source_hash ||= {}
    end

    # @return [Solargraph::ApiMap]
    def api_map
      @api_map ||= Solargraph::ApiMap.new(workspace)
    end

    # @return [Solargraph::Workspace]
    def workspace
      @workspace
    end

    # @param filename [String]
    # @return [Solargraph::Source]
    def read filename
      source = source_hash[filename]
      raise FileNotFoundError, "Source not found for #{filename}" if source.nil?
      # api_map.virtualize source
      source
    end
  end
end
