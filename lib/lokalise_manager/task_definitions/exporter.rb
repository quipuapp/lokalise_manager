# frozen_string_literal: true

require 'base64'

module LokaliseManager
  module TaskDefinitions
    class Exporter < Base
      # Performs translation file export to Lokalise and returns an array of queued processes
      #
      # @return [Array]
      def export!
        check_options_errors!

        queued_processes = []
        each_file do |full_path, relative_path|
          queued_processes << do_upload(full_path, relative_path)
        rescue StandardError => e
          raise e.class, "Error while trying to upload #{full_path}: #{e.message}"
        end

        $stdout.print('Task complete!') unless config.silent_mode

        queued_processes
      end

      private

      # Performs the actual file uploading to Lokalise. If the API rate limit is exceeed,
      # applies exponential backoff
      def do_upload(f_path, r_path)
        with_exp_backoff(config.max_retries_export) do
          api_client.upload_file project_id_with_branch, opts(f_path, r_path)
        end
      end

      # Processes each translation file in the specified directory
      def each_file
        return unless block_given?

        loc_path = config.locales_path
        Dir["#{loc_path}/**/*"].sort.each do |f|
          full_path = Pathname.new f

          next unless file_matches_criteria? full_path

          relative_path = full_path.relative_path_from Pathname.new(loc_path)

          yield full_path, relative_path
        end
      end

      # Generates export options
      #
      # @return [Hash]
      # @param full_p [Pathname]
      # @param relative_p [Pathname]
      def opts(full_p, relative_p)
        content = File.read full_p

        initial_opts = {
          data: Base64.strict_encode64(content.strip),
          filename: relative_p,
          lang_iso: config.lang_iso_inferer.call(content)
        }

        initial_opts.merge config.export_opts
      end

      # Checks whether the specified file has to be processed or not
      #
      # @return [Boolean]
      # @param full_path [Pathname]
      def file_matches_criteria?(full_path)
        full_path.file? && proper_ext?(full_path) &&
          !config.skip_file_export.call(full_path)
      end
    end
  end
end