require 'fluent/engine'
require 'fluent/plugin/input'
require 'fluent/compat/parser'

module Fluent::Plugin
  class CatSweepInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('cat_sweep', self)

    helpers :compat_parameters, :parser

    class OneLineMaxBytesOverError < StandardError
    end

    class FormatError < StandardError
    end

    config_param :file_path_with_glob,     :string
    config_param :waiting_seconds,         :integer  # seconds
    config_param :tag,                     :string,  :default => 'file.cat_sweep'
    config_param :processing_file_suffix,  :string,  :default => '.processing'
    config_param :error_file_suffix,       :string,  :default => '.error'
    config_param :line_terminated_by,      :string,  :default => "\n"
    config_param :oneline_max_bytes,       :integer, :default => 536870912 # 512MB
    config_param :move_to,                 :string,  :default => '/tmp'
    config_param :remove_after_processing, :bool,    :default => false
    config_param :run_interval,            :time,    :default => 5
    config_param :file_event_stream,       :bool,    :default => false
    config_param :flock_with_rw_mode,      :bool,    :default => false

    def configure(conf)
      compat_parameters_convert(conf, :parser, :buffer, :extract, default_chunk_key: "time")
      super

      configure_parser(conf)

      if @processing_file_suffix.empty?
        raise Fluent::ConfigError, "in_cat_sweep: `processing_file_suffix` must has some letters."
      end

      if @error_file_suffix.empty?
        raise Fluent::ConfigError, "in_cat_sweep: `error_file_suffix` must has some letters."
      end

      if @line_terminated_by.empty?
        raise Fluent::ConfigError, "in_cat_sweep: `line_terminated_by` must has some letters."
      end

      if !remove_file?
        first_filename = Dir.glob(@file_path_with_glob).first
        dirname = first_filename ? move_dirname(first_filename) : @move_to
        if Dir.exist?(dirname)
          if !File.writable?(dirname)
            raise Fluent::ConfigError, "in_cat_sweep: `move_to` directory (#{dirname}) must be writable."
          end
        else
          begin
            FileUtils.mkdir_p(dirname)
          rescue
            raise Fluent::ConfigError, "in_cat_sweep: `move_to` directory (#{dirname}) must be writable."
          end
        end
      end

      @read_bytes_once = 262144 # 256 KB

    end

    def start
      super

      @processing = true
      @thread = Thread.new(&method(:run_periodic))
    end

    def shutdown
      @processing = false
      @thread.join

      super
    end

    def run_periodic
      while @processing
        sleep @run_interval

        Dir.glob(@file_path_with_glob).map do |filename|
          next unless will_process?(filename)

          processing_filename = get_processing_filename(filename)
          begin
            lock_with_renaming(filename, processing_filename) do
              process(filename, processing_filename)
              after_processing(processing_filename)
            end
          rescue => e
            log.error "in_cat_sweep: processing: #{processing_filename}", :error => e, :error_class => e.class
            log.error_backtrace
            safe_fail(e, processing_filename)
          end
        end
      end
    end

    private

    def configure_parser(conf)
      @parser = parser_create()
    end

    def will_process?(filename)
      !(processing?(filename) or error_file?(filename) or sufficient_waiting?(filename))
    end

    def processing?(filename)
      filename.end_with?(@processing_file_suffix)
    end

    def error_file?(filename)
      filename.end_with?(@error_file_suffix)
    end

    def sufficient_waiting?(filename)
      (Time.at(Fluent::EventTime.now.to_r) - File.mtime(filename)).to_i < @waiting_seconds
    end

    def get_processing_filename(filename)
      tmpfile = String.new
      tmpfile << filename << '.' << Process.pid.to_s << '.'
      tmpfile << Fluent::EventTime.now.to_s << @processing_file_suffix
    end

    def revert_processing_filename(processing_filename)
      tmpfile = processing_filename.dup
      tmpfile.chomp!(@processing_file_suffix)
      tmpfile.gsub!(/\.\d+\.\d+$/, '')
    end

    def get_error_filename(e, filename)
      errfile = String.new
      errfile << filename << "." << e.class.to_s << @error_file_suffix
    end

    def safe_fail(e, filename)
      begin
        error_filename = get_error_filename(e, filename)
        lock_with_renaming(filename, error_filename)
      rescue => e
        log.error "in_cat_sweep: rename #{filename} to error filename #{error_filename}",
          :error => e, :error_class => e.class
        log.error_backtrace
      end
    end

    def buffer_clean!
      @buffer = String.new.force_encoding('ASCII-8BIT')
    end

    def buffer
      @buffer || buffer_clean!
    end

    def remove_file?
      @remove_after_processing
    end

    def read_each_line(io)
      buffer_clean!

      io.each(@line_terminated_by, @read_bytes_once) do |like_line|
        buffer << like_line

        if buffer.length > @oneline_max_bytes
          begin
            raise OneLineMaxBytesOverError,
              "in_cat_sweep: buffer length is over #{@oneline_max_bytes} bytes. remove: #{buffer}"
          ensure
            buffer_clean!
          end
        end

        if buffer.end_with?(@line_terminated_by)
          yield(buffer.chomp!(@line_terminated_by))
          buffer_clean!
        end
      end
      yield(buffer.chomp!(@line_terminated_by))
      buffer_clean!
    end

    def emit_line(line)
      if line
        time, record = parse_line(line)
        if time and record
          router.emit(@tag, time, record)
        end
      end
    end

    def emit_file(fp)
      entries = []
      read_each_line(fp) do |line|
        if line
          entry = parse_line(line)
          entries << entry if entry
        end
      end
      unless entries.empty?
        es = Fluent::ArrayEventStream.new(entries)
        router.emit_stream(@tag, es)
      end
    end

    def parse_line(line)
      entry = nil
      @parser.parse(line) do |time, record|
        if time && record
          entry = [time, record]
        else
          # We want to fail an entire file on `pattern not match`
          # This behavior makes it easy to recover with manual fix operation
          raise FormatError,
            "in_cat_sweep: pattern not match: #{line.inspect}"
        end
      end
      entry
    end

    def process(original_filename, processing_filename)
      File.open(processing_filename, 'r') do |tfile|
        if @file_event_stream
          emit_file(tfile)
        else
          read_each_line(tfile) do |line|
            emit_line(line)
          end
        end
        log.debug { %[in_cat_sweep: process: {filename:"#{original_filename}",size:#{tfile.size}}] }
      end
    end

    def open_mode_for_flock
      # When doing flock files on NFS, these files must be opend with writable mode.
      @open_mode_for_flock ||= @flock_with_rw_mode ? "r+" : "r"
    end

    def lock_with_renaming(filename_from, filename_to)
      file = File.open(filename_from, open_mode_for_flock)
      begin
        if file.flock(File::LOCK_EX | File::LOCK_NB)
          File.rename(filename_from, filename_to)
          yield if block_given?
        else
          log.warn "in_cat_sweep: lock failed: skip #{filename_from}"
        end
      ensure
        file.flock(File::LOCK_UN) # release the lock
        file.close
      end
    end

    def move_dirname(filename)
      File.join(@move_to, File.dirname(File.expand_path(filename)))
    end

    def after_processing(processing_filename)
      if remove_file?
        FileUtils.rm(processing_filename)
      else
        dirname = move_dirname(processing_filename)
        FileUtils.mkdir_p(dirname)
        filename = revert_processing_filename(File.basename(processing_filename))
        FileUtils.mv(processing_filename, File.join(dirname, filename))
      end
    end
  end
end
