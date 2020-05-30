#! /usr/bin/env ruby

# A script for generating a 'avr-rust/llvm' fork based off the 'rust-lang/llvm' fork.
#
# Cherry-picks all possible AVR fixes from LLVM master that are not in rust-lang/llvm.

require 'byebug'
require 'fileutils'
require 'date'

LLVM_SUBMODULE_RELATIVE_PATH = File.join("src", "llvm-project")
UPSTREAM_LLVM_URL = "https://github.com/llvm/llvm-project.git"

class Commit < Struct.new(:sha, :summary)
  def to_s
    [sha, summary].join(' ')
  end
end

class ForkScriptError < StandardError; end
class CommandExecutionError < ForkScriptError; end

def fatal_error(message)
  $stderr.puts "error: #{message}"
  exit 1
end

def run(command, **options)
  status_code, command_output = nil

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

module Util
  def self.validate_rust_checkout!(path:)
    raise "rust checkout path #{path} is not a directory" unless File.directory?(path)
  end

  def self.get_llvm_submodule_sha(rust_checkout_path:)
    status_parts = run(["git", "submodule", "status", LLVM_SUBMODULE_RELATIVE_PATH], :chdir => rust_checkout_path).split(' ')
    status_parts.first.gsub('+', '')
  end

  def self.avr_commitlog(ref:, repository_path:, max_count: 1000)
    run(["git", "log", "--oneline", ref, "--grep", "AVR", "-n", max_count.to_s], :chdir => repository_path).split("\n").map(&:chomp).map do |log_line|
      first_space = log_line.index(' ')
      Commit.new(log_line[0..first_space-1].strip, log_line[first_space+1..].strip)
    end
  end

  def self.find_rust_llvm_submodule_base_upstream_sha(rustllvm_ref:, llvm_master_ref:, llvm_submodule_path:, llvm_repo_path:)
    most_recent_rust_llvm_commits = avr_commitlog(:ref => rustllvm_ref, :repository_path => llvm_submodule_path)
    most_recent_llvm_master_commits = avr_commitlog(:ref => llvm_master_ref, :repository_path => llvm_repo_path, :max_count => 80000)

    most_recent_rust_llvm_commits.each do |commit|
      matching_upstream_llvm_commit = most_recent_llvm_master_commits.find { |c| c.summary.size > 10 && c.summary == commit.summary }

      return matching_upstream_llvm_commit.sha if matching_upstream_llvm_commit
    end
  end

  module Git
    def self.is_conflicting?(repository_path:)
      !run(["git", "ls-files", "-u"]).chomp.empty?
    end

  end
end

def log_step(description, &block)
  $stdout.puts "[note]: #{description}"
  block.call
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

def build_fork(arguments)
  fatal_error "please pass the path to the local Rust checkout on the command line" if arguments.size < 1
  fatal_error "please pass the path to the target directory for the AVR fork on the command line" if arguments.size < 2

  rust_checkout_path = File.realpath(arguments[0])
  target_fork_path = File.expand_path(arguments[1])

  Util.validate_rust_checkout!(:path => rust_checkout_path)
  llvm_submodule_path = File.join(rust_checkout_path, LLVM_SUBMODULE_RELATIVE_PATH)

  upstream_rust_llvm_sha = Util.get_llvm_submodule_sha(:rust_checkout_path => rust_checkout_path)
  log_info "base rust-lang/llvm SHA: #{upstream_rust_llvm_sha}"

  raise ForkScriptError, "the target fork directory '#{target_fork_path}' already exists" if File.exists?(target_fork_path)
  FileUtils.mkdir_p(target_fork_path)

  Dir.chdir(target_fork_path) do
    run(["git", "init"])
    run(["git", "remote", "add", "rust-lang-local", llvm_submodule_path])
    run(["git", "remote", "add", "upstream-llvm", UPSTREAM_LLVM_URL])
    log_step("fetch changes from local rust-lang LLVM repository (#{llvm_submodule_path})") { run(["git", "fetch", "rust-lang-local"]) }
    log_step("fetch changes from upstream LLVM (#{UPSTREAM_LLVM_URL})") { run(["git", "fetch", "upstream-llvm"]) }

    upstream_base_llvm_sha = log_step("finding the commit that both rust-lang and LLVM master have in common") do
      Util.find_rust_llvm_submodule_base_upstream_sha(:rustllvm_ref => upstream_rust_llvm_sha, :llvm_master_ref => "upstream-llvm/master", :llvm_submodule_path => llvm_submodule_path, :llvm_repo_path => '.')
    end
    log_info "base LLVM upstream SHA: #{upstream_base_llvm_sha}"

    version_name = "10.0-#{Date.today.strftime("%Y-%m-%d")}"

    log_step("checking out the rust-lang/llvm commit (#{upstream_rust_llvm_sha})") { run(["git", "checkout", upstream_rust_llvm_sha]) }
    # keep track of the originating rust-lang ref in a branch.
    run(["git", "checkout", "-b", "avr-rustc-rustlang-upstream/#{version_name}"])

    commits_to_cherry_pick = Util.avr_commitlog(:ref => "#{upstream_rust_llvm_sha}..upstream-llvm/master", :repository_path => ".").reverse

    log_step("cherry-picking new upstream AVR LLVM patches") do
      commits_to_cherry_pick.each do |commit|
        begin
          run(["git", "cherry-pick", commit.sha])

          log_info "cherry-picked commit '#{commit}'"
        rescue CommandExecutionError
          if Util::Git.is_conflicting?(:repository_path => '.')
            $stdout.puts "NOTE: failed to cherry-pick '#{commit}' due to conflicts"

            prompt("what would you like to do",
              "skip this commit" => lambda { run(["git", "cherry-pick", "--abort"]) },
              "abort" => lambda { fatal_error("aborted") },
            )
          else
            raise # don't handle this error.
          end
        end
      end
    end

    run(["git", "checkout", "-b", "avr-rustc/#{version_name}"])
  end

  puts "finished building the fork. it can be found at #{target_fork_path}"
end

begin
  build_fork(ARGV)
rescue ForkScriptError => e
  fatal_error(e.message)
rescue Interrupt
  fatal_error("cancelled via interrupt")
end
