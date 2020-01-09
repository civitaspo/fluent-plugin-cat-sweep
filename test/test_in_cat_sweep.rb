require_relative 'helper'
require 'rr'
require 'fluent/plugin/in_cat_sweep'

class CatSweepInputTest < Test::Unit::TestCase
  include Fluent::Test::Helpers

  def setup
    Fluent::Test.setup
    FileUtils.mkdir_p(TMP_DIR_FROM)
    FileUtils.mkdir_p(TMP_DIR_TO)
  end

  def teardown
    FileUtils.rm_r(TMP_DIR_FROM)
    FileUtils.rm_r(TMP_DIR_TO)
  end

  TMP_DIR_FROM = '/tmp/fluent_plugin_test_in_cat_sweep_from'
  TMP_DIR_TO   = '/tmp/fluent_plugin_test_in_cat_sweep_to'

  CONFIG_BASE = %[
    file_path_with_glob #{TMP_DIR_FROM}/*
    run_interval 0.05
  ]

  CONFIG_MINIMUM_REQUIRED =
    CONFIG_BASE + %[
      <parse>
        @type tsv
        keys ""
      </parse>
      waiting_seconds 3
    ]

  CONFIG_MINIMUM_REQUIRED_IN_OLD_STYLE =
    CONFIG_BASE + %[
      format tsv
      keys ""
      waiting_seconds 4
    ]

  def create_driver(conf)
    Fluent::Test::Driver::Input.new(Fluent::Plugin::CatSweepInput).configure(conf)
  end

  def test_required_configure
    assert_raise(Fluent::ConfigError) do
      create_driver(%[])
    end

    assert_raise(Fluent::ConfigError) do
      create_driver(CONFIG_BASE)
    end

    assert_raise(Fluent::ConfigError) do
      create_driver(CONFIG_BASE + %[
        <parse>
          @type tsv
          keys ""
        </parse>
      ])
    end

    d = create_driver(CONFIG_MINIMUM_REQUIRED)

    assert_equal "#{TMP_DIR_FROM}/*", d.instance.instance_variable_get(:@file_path_with_glob)
    assert_equal Fluent::Plugin::TSVParser, d.instance.instance_variable_get(:@parser).class
    assert_equal 3, d.instance.instance_variable_get(:@waiting_seconds)

    d = create_driver(CONFIG_MINIMUM_REQUIRED_IN_OLD_STYLE)

    assert_equal "#{TMP_DIR_FROM}/*", d.instance.instance_variable_get(:@file_path_with_glob)
    assert_equal Fluent::Plugin::TSVParser, d.instance.instance_variable_get(:@parser).class
    assert_equal 4, d.instance.instance_variable_get(:@waiting_seconds)
  end

  def test_configure_file_event_stream
    d = create_driver(CONFIG_MINIMUM_REQUIRED)
    assert { false == d.instance.file_event_stream }

    d = create_driver(CONFIG_MINIMUM_REQUIRED + %[file_event_stream true])
    assert { true == d.instance.file_event_stream }
  end

  def compare_test_result(events, tests)
    events.each_index do |i|
      assert { tests[i]['expected'] == events[i][2]['message'] }
    end
  end

  TEST_CASES =
    {
      'none' => [
        {'msg' => "tcptest1\n", 'expected' => 'tcptest1'},
        {'msg' => "tcptest2\n", 'expected' => 'tcptest2'},
      ],
      'tsv' => [
        {'msg' => "t.e.s.t.1\t12345\ttcptest1\t{\"json\":1}\n", 'expected' => '{"json":1}'},
        {'msg' => "t.e.s.t.2\t54321\ttcptest2\t{\"json\":\"char\"}\n", 'expected' => '{"json":"char"}'},
      ],
      'json' => [
        {'msg' => {'k' => 123, 'message' => 'tcptest1'}.to_json + "\n", 'expected' => 'tcptest1'},
        {'msg' => {'k' => 'tcptest2', 'message' => 456}.to_json + "\n", 'expected' => 456},
      ]
    }

  [false, true].each do |file_event_stream|
    TEST_CASES.each do |format, test_cases|
      test_case_name = "test_msg_process_#{format}_file_event_stream_#{file_event_stream}"
      define_method(test_case_name) do
        File.open("#{TMP_DIR_FROM}/#{test_case_name}", 'w') do |io|
          test_cases.each do |test|
            io.write(test['msg'])
          end
        end

        d = create_driver(CONFIG_BASE + %[
          format #{format}
          file_event_stream #{file_event_stream}
          waiting_seconds 0
          keys hdfs_path,unixtimestamp,label,message
          ])
        d.run

        compare_test_result(d.events, test_cases)
        assert { Dir.glob("#{TMP_DIR_FROM}/#{test_case_name}*").empty? }
      end
    end
  end

  def test_move_file
    format = 'tsv'
    test_cases =
      [
        {'msg' => "t.e.s.t.1\t12345\ttcptest1\t{\"json\":1}\n", 'expected' => '{"json":1}'},
        {'msg' => "t.e.s.t.2\t54321\ttcptest2\t{\"json\":\"char\"}\n", 'expected' => '{"json":"char"}'},
      ]

    File.open("#{TMP_DIR_FROM}/test_move_file", 'w') do |io|
      test_cases.each do |test|
        io.write(test['msg'])
      end
    end

    d = create_driver(CONFIG_BASE + %[
      format #{format}
      waiting_seconds 0
      keys hdfs_path,unixtimestamp,label,message
      move_to #{TMP_DIR_TO}
      ])
    d.run

    compare_test_result(d.events, test_cases)

    assert(Dir.glob("#{TMP_DIR_FROM}/test_move_file*").empty?)
    assert_match(
      %r{\A#{TMP_DIR_TO}#{TMP_DIR_FROM}/test_move_file},
      Dir.glob("#{TMP_DIR_TO}#{TMP_DIR_FROM}/test_move_file*").first)
    assert_equal(
      test_cases.map{|t|t['msg']}.join.to_s,
      File.read(Dir.glob("#{TMP_DIR_TO}#{TMP_DIR_FROM}/test_move_file*").first))
  end

  def test_oneline_max_bytes
    format = 'tsv'
    test_cases =
      [
        {'msg' => "t.e.s.t.1\t12345\ttcptest1\t{\"json\":1}\n", 'expected' => '{"json":1}'},
        {'msg' => "t.e.s.t.2\t54321\ttcptest2\t{\"json\":\"char\"}\n", 'expected' => '{"json":"char"}'},
      ]

    File.open("#{TMP_DIR_FROM}/test_oneline_max_bytes", 'w') do |io|
      test_cases.each do |test|
        io.write(test['msg'])
      end
    end

    d = create_driver(CONFIG_BASE + %[
      format #{format}
      waiting_seconds 0
      keys hdfs_path,unixtimestamp,label,message
      move_to #{TMP_DIR_TO}
      oneline_max_bytes 1
      ])

    d.run

    assert_match(
      %r{\A#{TMP_DIR_FROM}/test_oneline_max_bytes.*\.error},
      Dir.glob("#{TMP_DIR_FROM}/test_oneline_max_bytes*").first)
      assert_equal(
        test_cases.map{|t|t['msg']}.join.to_s,
        File.read(Dir.glob("#{TMP_DIR_FROM}/test_oneline_max_bytes*.error").first))
  end
end
