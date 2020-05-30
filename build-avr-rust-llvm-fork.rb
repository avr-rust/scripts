#! /usr/bin/env ruby

# A script for generating a 'avr-rust/llvm' fork based off the 'rust-lang/llvm' fork.
#
# Cherry-picks all possible AVR fixes from LLVM master that are not in rust-lang/llvm.

require 'fileutils'
require 'date'
require 'optparse'
require 'ostruct'
require 'json'
require 'tmpdir'

RUST_LLVM_SUBMODULE_RELATIVE_PATH = File.join("src", "llvm-project")
DEFAULT_LLVM_VERSION_NUMBER_FOR_OUTPUT_BRANCHES = "10.0"

module DefaultOptions
  UPSTREAM_LLVM_URL = "https://github.com/llvm/llvm-project.git"

  # Until https://github.com/rust-lang/rust/pull/69478 is merged,
  # we have to base off of the avr-support-upstream branch rather
  # than actual upstream Rust.
  UPSTREAM_RUST_URL = "https://github.com/avr-rust/rust.git"
  UPSTREAM_RUST_REF = "avr-support-upstream"
end

class GeneralError < StandardError; end
class CommandExecutionError < GeneralError; end
class InvalidCliOptionError < GeneralError; end


module Support
  module Prelude
    def fatal_error(message)
      $stderr.puts "error: #{message}"
      exit 1
    end

    def step(description, &block)
      hr = '=' * 40

      puts "#{hr}\n#{description.strip}\n#{hr}\n\n"
      retval = block.call

      puts "#{hr}\n"
      retval
    end

    def step_newgen(description, details = {}, &block)
      hr = '=' * 26

      puts "#{'=' * 13} BEGIN: #{description} #{hr}"
      puts
      unless details.empty?
        puts details.to_a.sort_by(&:first).map { |k, v| "   - #{k.to_s.capitalize}: #{v.inspect}" }.join("\n")
        puts hr * 3
      end

      retval = block.call

      puts
      puts "#{hr} END: #{description} #{hr}"
      puts

      retval
    end

    def run(command, **options)
      status_code, command_output = nil
      command_line = Array(command).join(' ')

      $stdout.puts "[execute] $ #{command_line}    # (working directory: #{File.realpath(options[:chdir] || Dir.pwd)})"

      IO.popen(command, **options) do |io|
        command_output = io.read

        io.close
        status_code = $?.exitstatus
      end

      if status_code != 0
        raise CommandExecutionError, "command '#{command.inspect}' failed with exit code #{status_code}"
      end

      command_output
    end

    def log_info(description)
      $stdout.puts "[info]: #{description}"
    end

    def prompt(question, **answers_hash)
      answer_values = answers_hash.keys.map(&:to_s).sort
      abbrevs_by_answer = answer_values.map { |a| [a, a[0]]}.to_h
      handlers_by_abbrev = answers_hash.map { |a, h| [abbrevs_by_answer[a], h] }.to_h

      $stdout.puts question
      $stdout.print " enter value (#{answer_values.map { |a| "'#{abbrevs_by_answer[a]}' for #{a}" }.join(', ')})>> "

      while true
        a = $stdin.gets.chomp

        if (handler = handlers_by_abbrev[a])
          handler.call
          break
        else
          $stdout.puts "error: '#{a}' is not a valid answer"
        end
      end
    end
  end

  class Commit < Struct.new(:sha, :summary)
    def to_s
      [sha, summary].join(' ')
    end
  end

  module ConflictAction
    SKIP = "skip"
    ABORT = "abort"
    INTERACTIVE_PROMPT = "prompt"

    ALL = [SKIP, ABORT, INTERACTIVE_PROMPT]

    def self.perform!(conflict_action)
      case conflict_action
      when ConflictAction::ABORT then perform_abort!
      when ConflictAction::SKIP then perform_skip!
      when ConflictAction::INTERACTIVE_PROMPT
        prompt("what would you like to do",
          "skip this commit" => lambda { perform_skip! },
          "abort" => lambda { perform_abort! },
        )
      end
    end

    def self.perform_skip!
      log_info "skipping this cherry-pick because it has merge conflicts"

      run(["git", "cherry-pick", "--abort"])
    end

    def self.perform_abort!
      fatal_error("aborted due to merge conflicts")
    end
  end
end

module GitUtil
  def self.get_llvm_submodule_sha(upstream_rust_path:)
    status_parts = run(["git", "submodule", "status", RUST_LLVM_SUBMODULE_RELATIVE_PATH], :chdir => upstream_rust_path).split(' ')
    status_parts.first.gsub('+', '').gsub('-', '')
  end

  def self.get_llvm_submodule_url(upstream_rust_path:)
    raw = run(["git", "config", "--blob", "HEAD:.gitmodules",  "--list"], :chdir => upstream_rust_path)
    parts = raw.lines.map { |line| idx = line.index('='); [line[0..(idx-1)].strip, line[(idx+1)..-1].strip] }.to_h

    parts["submodule.src/llvm-project.url"] or raise "cannot find LLVM submodule URL"
  end

  def self.avr_commitlog(ref:, repository_path:, max_count: 1000)
    run(["git", "log", "--oneline", ref, "--grep", "AVR", "-n", max_count.to_s], :chdir => repository_path).split("\n").map(&:chomp).map do |log_line|
      first_space = log_line.index(' ')
      Commit.new(log_line[0..(first_space-1)].strip, log_line[(first_space+1)..-1].strip)
    end
  end

  def self.find_rust_llvm_submodule_base_upstream_sha(rustllvm_ref:, llvm_master_ref:, llvm_repo_path:)
    most_recent_rust_llvm_commits = avr_commitlog(:ref => rustllvm_ref, :repository_path => llvm_repo_path)
    most_recent_llvm_master_commits = avr_commitlog(:ref => llvm_master_ref, :repository_path => llvm_repo_path, :max_count => 80000)

    most_recent_rust_llvm_commits.each do |commit|
      matching_upstream_llvm_commit = most_recent_llvm_master_commits.find { |c| c.summary.size > 10 && c.summary == commit.summary }

      return matching_upstream_llvm_commit.sha if matching_upstream_llvm_commit
    end
  end

  def self.is_conflicting?(repository_path:)
    !run(["git", "ls-files", "-u"]).chomp.empty?
  end
end

include Support::Prelude

def build_fork(options)
  destination_directory_rust = options.destination_directory
  destination_directory_llvm = File.join(destination_directory_rust, RUST_LLVM_SUBMODULE_RELATIVE_PATH)
  datestamp = Date.today.strftime("%Y-%m-%d")
  version_name = "llvm-#{DEFAULT_LLVM_VERSION_NUMBER_FOR_OUTPUT_BRANCHES}-#{datestamp}"

  if File.exists?(destination_directory_rust)
    raise GeneralError, "the target fork directory '#{destination_directory_rust}' already exists"
  end

  FileUtils.mkdir_p(destination_directory_rust)

  step_newgen(
    "cloning the upstream Rust repository",
    "upstream Rust repository" => options.upstream_rust_path_or_url, "destination path" => destination_directory_rust
  ) do
    Dir.chdir(destination_directory_rust) do
      run(["git", "init"])
      run(["git", "remote", "add", "upstream-rust", options.upstream_rust_path_or_url])
      run(["git", "fetch", "upstream-rust", options.upstream_rust_ref])
      run(["git", "checkout", "-b", "avr-rustc/rustlang-upstream/#{version_name}", "upstream-rust/#{options.upstream_rust_ref}"])

    end
  end

  step_newgen(
    "fetching the upstream Rust LLVM submodule",
    "submodule path" => destination_directory_llvm,
  ) do
    Dir.chdir(destination_directory_rust) do
      run(["git", "submodule", "update", "--init", RUST_LLVM_SUBMODULE_RELATIVE_PATH])
    end

    Dir.chdir(destination_directory_llvm) do
      # rename 'origin' to 'upstream-rust-lang-llvm' for consistency.
      run(["git", "remote", "rename", "origin", "upstream-rust-lang-llvm"])
    end
  end

  upstream_rust_llvm_url = GitUtil.get_llvm_submodule_url(:upstream_rust_path => destination_directory_rust)
  upstream_rust_llvm_sha = GitUtil.get_llvm_submodule_sha(:upstream_rust_path => destination_directory_rust)

  log_info "base rust-lang/llvm SHA: #{upstream_rust_llvm_sha}"

  step_newgen(
    "fetching changes from upstream LLVM to the Rust LLVM submodule",
    "submodule path" => destination_directory_llvm,
    "upstream LLVM" => options.upstream_llvm_path_or_url,
  ) do
    run(["git", "remote", "add", "upstream-llvm", options.upstream_llvm_path_or_url])
    run(["git", "fetch", "upstream-llvm", options.upstream_llvm_ref])
  end

  exit 0



  FileUtils.mkdir_p(destination_directory)

  Dir.chdir(destination_directory) do
    run(["git", "config", "merge.renamelimit", "35000"]) # get rid of annoying warnings

    upstream_base_llvm_sha = step("finding the commit that both rust-lang and upstream LLVM #{options.upstream_llvm_ref} have in common") do
      GitUtil.find_rust_llvm_submodule_base_upstream_sha(:rustllvm_ref => upstream_rust_llvm_sha, :llvm_master_ref => "upstream-llvm/#{options.upstream_llvm_ref}", :llvm_repo_path => '.')
    end
    log_info "base LLVM upstream SHA: #{upstream_base_llvm_sha}"

    version_name = "#{DEFAULT_LLVM_VERSION_NUMBER_FOR_OUTPUT_BRANCHES}-#{Date.today.strftime("%Y-%m-%d")}"

    step("checking out the rust-lang/llvm commit (#{upstream_rust_llvm_sha})") { run(["git", "checkout", upstream_rust_llvm_sha]) }

    # keep track of the originating rust-lang ref in a branch.
    run(["git", "checkout", "-b", "avr-rustc-rustlang-upstream/#{version_name}", upstream_rust_llvm_sha])

    commits_to_cherry_pick = GitUtil.avr_commitlog(:ref => "#{upstream_rust_llvm_sha}..upstream-llvm/#{options.upstream_llvm_ref}", :repository_path => ".").reverse

    step("cherry-picking new upstream AVR LLVM patches") do
      commits_to_cherry_pick.each do |commit|
        begin
          run(["git", "cherry-pick", commit.sha])

          log_info "cherry-picked commit '#{commit}'"
        rescue CommandExecutionError
          if GitUtil.is_conflicting?(:repository_path => '.')
            $stdout.puts "NOTE: failed to cherry-pick '#{commit}' due to conflicts"

            ConflictAction.perform!(options.conflict_action)
          else
            raise # don't handle this error.
          end
        end
      end
    end

    run(["git", "checkout", "-b", "avr-rustc/#{version_name}"])
  end

  puts "finished building the LLVM fork. it can be found at #{destination_directory}"
end

def build_fork_cli
  options = {
    :upstream_rust_path_or_url => DefaultOptions::UPSTREAM_RUST_URL,
    :upstream_rust_ref => DefaultOptions::UPSTREAM_RUST_REF,
    :upstream_llvm_path_or_url => DefaultOptions::UPSTREAM_LLVM_URL,
    :upstream_llvm_ref => "master",
    :conflict_action => Support::ConflictAction::INTERACTIVE_PROMPT,
  }


  OptionParser.new do |opt|
    default_options = OpenStruct.new(options)
    padding = 36.times.map { ' ' }.join

    opt.banner = "Usage: #{File.basename(__FILE__)} <BASE RUST GIT URL OR PATH> <DESTINATION PATH> [OPTIONS]\n\nCreates an avr-rust fork from the upstream branch.\n\n"

    opt.on('--on-conflict ACTION', "Sets the default action to be taken when cherry-picking commits that conflict. Possible options are: #{Support::ConflictAction::ALL.join(', ')}") do |o|
      raise InvalidCliOptionError, "invalid on-conflict action: #{o.inspect}. possible options are: #{Support::ConflictAction::ALL.join(', ')}" unless Support::ConflictAction::ALL.include?(o)
      options[:conflict_action] = o
    end

    opt.on('--upstream-rust-repo REPO_PATH_OR_URL', "Sets the upstream Rust repository to be used.\n\n#{padding} Defaults to #{default_options.upstream_rust_path_or_url.inspect}") do |p|
      options[:upstream_rust_path_or_url] = p
    end

    opt.on('--upstream-rust-ref GIT_REF', "Sets the branch name to be considered the upstream Rust branch on the upstream Rust repository.\n\n#{padding} Defaults to #{default_options.upstream_rust_ref.inspect}") do |r|
      options[:upstream_rust_ref] = r
    end

    opt.on('--upstream-llvm-repo REPO_PATH_OR_URL', "Sets the upstream LLVM repository to be used.\n\n#{padding} Defaults to #{default_options.upstream_llvm_path_or_url.inspect}") do |p|
      options[:upstream_llvm_path_or_url] = p
    end

    opt.on('--upstream-llvm-ref GIT_REF', "Sets the branch name to be considered the upstream LLVM branch on the upstream LLVM repository.\n\n#{padding} Defaults to #{default_options.upstream_llvm_ref.inspect}") do |r|
      options[:upstream_llvm_ref] = r
    end
  end.parse!


  fatal_error "please pass the path to the target directory for the AVR fork as the second argument on the command line" if ARGV.size < 1
  fatal_error "too many positional arguments specified on the command line" if ARGV.size > 1

  options[:destination_directory] = File.expand_path(ARGV[0])

  options = OpenStruct.new(options)

  puts "Command Line Options: #{JSON.pretty_generate(options.to_h.sort_by { |k, _| k }.to_h)}\n\n"

  build_fork(options)
end

begin
  build_fork_cli
rescue GeneralError => e
  fatal_error(e.message)
rescue Interrupt
  fatal_error("cancelled via interrupt")
end
