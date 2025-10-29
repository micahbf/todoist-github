#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'fileutils'
require 'date'

# GitHub-Todoist PR Review Sync
# Syncs GitHub pull request review requests to Todoist tasks
class GithubTodoistSync
  GITHUB_API_BASE = 'https://api.github.com'
  TODOIST_API_BASE = 'https://api.todoist.com/rest/v2'
  STATE_FILE = File.expand_path('~/.github_todoist_sync_state.json')

  def initialize(github_token:, todoist_token:, todoist_project_id: nil, todoist_section_id: nil)
    @github_token = github_token
    @todoist_token = todoist_token
    @todoist_project_id = todoist_project_id
    @todoist_section_id = todoist_section_id
    @state = load_state
  end

  def sync
    puts "Starting GitHub-Todoist sync..."

    # Fetch PRs requesting review (search API only, no filtering yet)
    all_review_requests = fetch_github_review_requests_search_only
    puts "Found #{all_review_requests.length} PR(s) requesting review (may include team requests)"

    # Only fetch PR details for PRs not yet in our state
    # (PRs already in state have been validated as direct requests previously)
    new_prs = all_review_requests.reject { |pr| @state['pr_to_task'].key?(pr['html_url']) }
    existing_pr_urls = all_review_requests.select { |pr| @state['pr_to_task'].key?(pr['html_url']) }.map { |pr| pr['html_url'] }.to_set

    puts "#{new_prs.length} new PR(s) to validate, #{existing_pr_urls.size} already tracked"

    # Validate new PRs to check if directly requested
    directly_requested_new_prs = new_prs.select { |pr| directly_requested_reviewer?(pr) }
    puts "#{directly_requested_new_prs.length} new PR(s) where you are directly requested"

    # Create tasks for new PRs where directly requested
    directly_requested_new_prs.each do |pr|
      pr_url = pr['html_url']
      task_id = create_todoist_task(pr)
      if task_id
        @state['pr_to_task'][pr_url] = task_id
        puts "Created task for PR: #{pr_url}"
      end
    end

    # Build set of all current PR URLs (both new direct requests and existing tracked)
    current_pr_urls = existing_pr_urls + directly_requested_new_prs.map { |pr| pr['html_url'] }

    # Complete tasks for PRs no longer requesting review
    @state['pr_to_task'].dup.each do |pr_url, task_id|
      next if current_pr_urls.include?(pr_url)

      if complete_todoist_task(task_id)
        @state['pr_to_task'].delete(pr_url)
        puts "Completed task for PR: #{pr_url}"
      end
    end

    save_state
    puts "Sync completed successfully"
  end

  private

  def fetch_github_review_requests_search_only
    # Use GitHub search API to find PRs where the authenticated user is requested as reviewer
    # This includes both direct and team-based requests
    uri = URI("#{GITHUB_API_BASE}/search/issues")
    params = { q: 'type:pr state:open review-requested:@me', per_page: 100 }
    uri.query = URI.encode_www_form(params)

    response = github_api_request(uri)

    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      data['items'] || []
    else
      puts "Error fetching GitHub PRs: #{response.code} #{response.message}"
      puts response.body if response.body
      []
    end
  rescue StandardError => e
    puts "Error fetching GitHub PRs: #{e.message}"
    []
  end

  def directly_requested_reviewer?(pr)
    # Extract repo owner and name from PR URL or repository_url
    repo_full_name = pr['repository_url']&.split('/')&.last(2)&.join('/')
    return false unless repo_full_name

    pr_number = pr['number']
    return false unless pr_number

    # Fetch full PR details to check requested_reviewers
    uri = URI("#{GITHUB_API_BASE}/repos/#{repo_full_name}/pulls/#{pr_number}")
    response = github_api_request(uri)

    if response.is_a?(Net::HTTPSuccess)
      pr_details = JSON.parse(response.body)
      requested_reviewers = pr_details['requested_reviewers'] || []

      # Get the authenticated user's login
      user_login = get_authenticated_user_login

      # Check if the authenticated user is in the requested_reviewers array
      requested_reviewers.any? { |reviewer| reviewer['login'] == user_login }
    else
      # If we can't fetch details, err on the side of inclusion
      true
    end
  rescue StandardError => e
    puts "Warning: Could not check if directly requested for PR #{pr['html_url']}: #{e.message}"
    # If we can't verify, err on the side of inclusion
    true
  end

  def get_authenticated_user_login
    @user_login ||= begin
      uri = URI("#{GITHUB_API_BASE}/user")
      response = github_api_request(uri)

      if response.is_a?(Net::HTTPSuccess)
        user_data = JSON.parse(response.body)
        user_data['login']
      else
        nil
      end
    rescue StandardError => e
      puts "Warning: Could not fetch authenticated user info: #{e.message}"
      nil
    end
  end

  def create_todoist_task(pr)
    repo_name = pr['repository_url']&.split('/')&.last(2)&.join('/') || 'Unknown repo'
    pr_title = pr['title']
    pr_url = pr['html_url']
    pr_number = pr['number']
    author = pr['user']['login']

    task_content = "Review PR ##{pr_number}: #{pr_title}"
    task_description = "Repository: #{repo_name}\nAuthor: @#{author}\nURL: #{pr_url}"

    uri = URI("#{TODOIST_API_BASE}/tasks")
    body = {
      content: task_content,
      description: task_description,
      priority: 1,
      due_date: Date.today.to_s # Set due date to today (YYYY-MM-DD format)
    }
    body[:project_id] = @todoist_project_id if @todoist_project_id
    body[:section_id] = @todoist_section_id if @todoist_section_id

    response = todoist_api_request(uri, :post, body)

    if response.is_a?(Net::HTTPSuccess)
      task_data = JSON.parse(response.body)
      task_data['id']
    else
      puts "Error creating Todoist task: #{response.code} #{response.message}"
      puts response.body if response.body
      nil
    end
  rescue StandardError => e
    puts "Error creating Todoist task: #{e.message}"
    nil
  end

  def complete_todoist_task(task_id)
    uri = URI("#{TODOIST_API_BASE}/tasks/#{task_id}/close")
    response = todoist_api_request(uri, :post)

    if response.is_a?(Net::HTTPNoContent) || response.is_a?(Net::HTTPSuccess)
      true
    else
      puts "Error completing Todoist task #{task_id}: #{response.code} #{response.message}"
      puts response.body if response.body
      false
    end
  rescue StandardError => e
    puts "Error completing Todoist task #{task_id}: #{e.message}"
    false
  end

  def github_api_request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@github_token}"
    request['Accept'] = 'application/vnd.github+json'
    request['X-GitHub-Api-Version'] = '2022-11-28'
    request['User-Agent'] = 'GitHub-Todoist-Sync'

    http.request(request)
  end

  def todoist_api_request(uri, method = :get, body = nil)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = case method
              when :post
                Net::HTTP::Post.new(uri)
              when :get
                Net::HTTP::Get.new(uri)
              else
                raise ArgumentError, "Unsupported HTTP method: #{method}"
              end

    request['Authorization'] = "Bearer #{@todoist_token}"
    request['Content-Type'] = 'application/json' if body
    request.body = body.to_json if body

    http.request(request)
  end

  def load_state
    if File.exist?(STATE_FILE)
      JSON.parse(File.read(STATE_FILE))
    else
      { 'pr_to_task' => {} }
    end
  rescue StandardError => e
    puts "Warning: Could not load state file: #{e.message}"
    { 'pr_to_task' => {} }
  end

  def save_state
    File.write(STATE_FILE, JSON.pretty_generate(@state))
  rescue StandardError => e
    puts "Error saving state file: #{e.message}"
  end
end

# Load environment variables from .env file
def load_env_file(file_path = '.env')
  return unless File.exist?(file_path)

  File.readlines(file_path).each do |line|
    line = line.strip
    # Skip comments and empty lines
    next if line.empty? || line.start_with?('#')

    # Parse KEY=VALUE pairs
    if line =~ /^([^=]+)=(.*)$/
      key = Regexp.last_match(1).strip
      value = Regexp.last_match(2).strip
      # Remove quotes if present
      value = value.gsub(/^["']|["']$/, '')
      ENV[key] = value unless value.empty?
    end
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  # Load .env file if it exists
  env_file_path = File.join(File.dirname(__FILE__), '.env')
  load_env_file(env_file_path)

  github_token = ENV['GITHUB_TOKEN']
  todoist_token = ENV['TODOIST_TOKEN']
  todoist_project_id = ENV['TODOIST_PROJECT_ID'] # Optional
  todoist_section_id = ENV['TODOIST_SECTION_ID'] # Optional

  if github_token.nil? || github_token.empty?
    puts "Error: GITHUB_TOKEN environment variable is required"
    puts "Please create a .env file with your tokens (see .env.example)"
    exit 1
  end

  if todoist_token.nil? || todoist_token.empty?
    puts "Error: TODOIST_TOKEN environment variable is required"
    puts "Please create a .env file with your tokens (see .env.example)"
    exit 1
  end

  sync = GithubTodoistSync.new(
    github_token: github_token,
    todoist_token: todoist_token,
    todoist_project_id: todoist_project_id,
    todoist_section_id: todoist_section_id
  )

  sync.sync
end
