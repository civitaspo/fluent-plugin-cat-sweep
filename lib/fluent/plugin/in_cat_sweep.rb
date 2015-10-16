
module Fluent
  class CatSweepInput < Input
    Plugin.register_input('cat_sweep', self)

    class OneLineMaxBytesOverError < StandardError
    end

    class FormatError < StandardError
    end

    config_param :file_path_with_glob,     :string
    config_param :format,                  :string
    config_param :waiting_seconds,         :integer  # seconds
    config_param :tag,                     :string,  :default => 'file.cat_sweep'
    config_param :processing_file_suffix,  :string,  :default => 'processing'
    config_param :error_file_suffix,       :string,  :default => 'error'
    config_param :line_terminated_by,      :string,  :default => "\n"
    config_param :oneline_max_bytes,       :integer, :default => 536870912 # 512MB
    config_param :move_to,                 :string,  :default => '/tmp'
    config_param :remove_after_processing, :bool,    :default => false
    config_param :run_interval,            :integer, :default => 5


    # To support log_level option implemented by Fluentd v0.10.43
    unless method_defined?(:log)
      define_method("log") { $log }
    end

    # Define `router` method of v0.12 to support v0.10 or earlier
    unless method_defined?(:router)
      define_method("router") { Fluent::Engine }
    end

    def configure(conf)
      super

      @parser = Plugin.new_parser(@format)
      @parser.configure(conf)

      if @processing_file_suffix.empty?
        raise Fluent::ConfigError, "in_cat_sweep: `processing_file_suffix` must has some letters."
      end

      if @error_file_suffix.empty?
        raise Fluent::ConfigError, "in_cat_sweep: `error_file_suffix` must has some letters."
      end

      if @line_terminated_by.empty?
        raise Fluent::ConfigError, "in_cat_sweep: `line_terminated_by` must has some letters."
      end

      if !remove_file? and !Dir.exists?(@move_to)
        raise Fluent::ConfigError, "in_cat_sweep: `move_to` directory must be existed."
      end

      @read_bytes_once = 262144 # 256 KB

    end

    def start
      @processing = true
      @thread = Thread.new(&method(:run_periodic))
    end

    def shutdown
      @processing = false
      @thread.join
    end

    def run_periodic
      while @processing
        sleep @run_interval

        Dir.glob(@file_path_with_glob).map do |filename|
          next unless will_process?(filename)

          processing_filename = get_processing_filename(filename)
          begin
            lock_with_renaming(filename, processing_filename) do
              process(processing_filename)
              after_processing(processing_filename)
            end
          rescue => e
            log.error "in_cat_sweep: processing error: #{e}, file: #{processing_filename}",
              :error => e, :error_class => e.class
            log.error_backtrace
            safe_fail(processing_filename)
          end
        end
      end
    end

    private

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
      (Time.now - File.mtime(filename)).to_i < @waiting_seconds
    end

    def get_processing_filename(filename)
      tmpfile = String.new
      tmpfile << filename << '.' << Process.pid.to_s << '.'
      tmpfile << Time.now.to_i.to_s << '.' << @processing_file_suffix
    end

    def get_error_filename(filename)
      errfile = String.new
      errfile << filename << '.' << @error_file_suffix
    end

    def safe_fail(filename)
      begin
        lock_with_renaming(filename, get_error_filename(filename))
      rescue => e
        log.error "in_cat_sweep: rename #{filename} to error name. message: #{e}",
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

    def emit_message(message)
      if message
        @parser.parse(message) do |time, record|
          unless time and record
            raise FormatError,
              "in_cat_sweep: pattern not match: #{message.inspect}"
          end
          router.emit(@tag, time, record)
        end
      end
    end

    def process(filename)
      File.open(filename, 'r') do |tfile|
        read_each_line(tfile) do |line|
          emit_message(line)
        end
      end
    end

    def lock_with_renaming(filename_from, filename_to)
      file = File.open(filename_from)
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

    def after_processing(filename)
      if remove_file?
        FileUtils.rm(filename)
      else
        FileUtils.mv(filename, @move_to)
      end
    end
  end
end
