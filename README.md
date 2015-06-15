# fluent-plugin-destructive-read

#### [Travis欲しいぃぃィィィィィィ]

Fluentd plugin to read data from files and remove or move after processing.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fluent-plugin-destructive-read'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fluent-plugin-destructive-read

## Configuration

```
<source>
  type destructive_read

  # Required. process files that match this pattern using glob.
  input_path /tmp/test/file_*

  # Input pattern. It depends on Parser plugin
  format tsv
  keys xpath,access_time,label,payload

  # Required. process files that are older than this parameter(seconds).
  # [WARNING!!]: this plugin move or remove files even if the files open,
  # so this parameter is set as seconds that the application close files definitely.  
  waiting_seconds 60

  # Optional. default is file.destructive_read
  tag test.input

  # Optional. processing files is renamed with this suffix. default is .processing
  processing_file_suffix .processing

  # Optional. error files is renamed with this suffix. default is .error
  error_file_suffix .err

  # Optional. line terminater. default is "\n"
  line_terminated_by ,

  # Optional. max bytes oneline can has. default 536870912 (512MB)
  oneline_max_bytes 128000

  # Optional. this parameter indicated,
  # files that is processed are not removed but move to processed_file_path.
  # default '/tmp'
  move_to /tmp/test_processed

  # Optional. this parameter indicated, `move_to` is ignored.
  # files that is processed are removed.
  # default is false.
  remove_after_processing true

  # Optional. default 5 seconds.
  run_interval 10
</source>
```

## Contributing

1. Fork it ( https://github.com/[my-github-username]/fluent-plugin-destructive-read/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
