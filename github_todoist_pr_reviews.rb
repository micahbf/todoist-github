#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'fileutils'
require 'date'
require 'set'

# GitHub-Todoist PR Reviews Sync
# Monitors your own PRs for new reviews and creates follow-up tasks
class GithubTodoistPrReviews
  GITHUB_API_BASE = 'https://api.github.com'
  TODOIST_API_BASE = 'https://api.todoist.com/rest/v2'

  def self.config_dir
    xdg_config = ENV['XDG_CONFIG_HOME'] || File.expand_path('~/.config')
    File.join(xdg_config, 'github-todoist')
  end

  STATE_FILE = File.join(config_dir, 'github_todoist_pr_reviews_state.json')

  def initialize(github_token:, todoist_token:, todoist_project_id: nil, todoist_section_id: nil)
    @github_token = github_token
    @todoist_token = todoist_token
    @todoist_project_id = todoist_project_id
    @todoist_section_id = todoist_section_id
    @state = load_state
    @user_login = nil
  end

  def sync
    puts "Starting PR reviews sync..."

    # Fetch all open PRs authored by me
    my_open_prs = fetch_my_open_prs
    puts "Found #{my_open_prs.length} open PR(s) authored by you"

    # Track which PRs are still open
    current_pr_urls = my_open_prs.map { |pr| pr['html_url'] }.to_set

    # For each PR, check for reviews and process
    my_open_prs.each do |pr|
      pr_url = pr['html_url']
      process_pr(pr)
    end

    # Complete tasks for PRs that are no longer open (closed or merged)
    @state['pr_reviews'].keys.each do |tracked_pr_url|
      unless current_pr_urls.include?(tracked_pr_url)
        complete_task_for_pr(tracked_pr_url, "PR is no longer open")
        @state['pr_reviews'].delete(tracked_pr_url)
        puts "Removed closed/merged PR from tracking: #{tracked_pr_url}"
      end
    end

    save_state
    puts "Sync completed successfully"
  end

  private

  def fetch_my_open_prs
    # Use GitHub search API to find open PRs authored by me
    uri = URI("#{GITHUB_API_BASE}/search/issues")
    params = { q: 'type:pr state:open author:@me', per_page: 100 }
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

  def process_pr(pr)
    pr_url = pr['html_url']
    repo_full_name = extract_repo_full_name(pr)
    return unless repo_full_name

    pr_number = pr['number']
    return unless pr_number

    # Fetch full PR details to check merge status and review requests
    pr_details = fetch_pr_details(repo_full_name, pr_number)
    return unless pr_details

    # Check if PR is merged - complete task if exists
    if pr_details['merged']
      complete_task_for_pr(pr_url, "PR was merged")
      return
    end

    # Check if there are any review requests (indicating a re-request)
    requested_reviewers = pr_details['requested_reviewers'] || []
    requested_teams = pr_details['requested_teams'] || []

    if !requested_reviewers.empty? || !requested_teams.empty?
      # PR has active review requests, complete existing task
      complete_task_for_pr(pr_url, "New review was requested")
      return
    end

    # Fetch all reviews for this PR
    reviews = fetch_pr_reviews(repo_full_name, pr_number)
    return if reviews.empty?

    # Initialize tracking for this PR if needed
    @state['pr_reviews'][pr_url] ||= { 'task_id' => nil, 'last_review_id' => nil }

    # Get the most recent review (reviews are returned chronologically)
    latest_review = reviews.last

    # Check if this is a new review or if we don't have a task yet
    if @state['pr_reviews'][pr_url]['last_review_id'] != latest_review['id']
      # Complete old task if it exists and create new task for this review
      complete_task_for_pr(pr_url, "New review received") if @state['pr_reviews'][pr_url]['task_id']

      # Create task for this PR
      task_id = create_review_task(pr, latest_review)
      if task_id
        @state['pr_reviews'][pr_url]['task_id'] = task_id
        @state['pr_reviews'][pr_url]['last_review_id'] = latest_review['id']
        puts "Created/updated follow-up task for PR: #{pr_url}"
      end
    end
  end

  def complete_task_for_pr(pr_url, reason)
    return unless @state['pr_reviews'][pr_url]

    task_id = @state['pr_reviews'][pr_url]['task_id']
    return unless task_id

    if complete_todoist_task(task_id)
      puts "Completed task for PR #{pr_url}: #{reason}"
      @state['pr_reviews'][pr_url]['task_id'] = nil
    end
  end

  def fetch_pr_details(repo_full_name, pr_number)
    uri = URI("#{GITHUB_API_BASE}/repos/#{repo_full_name}/pulls/#{pr_number}")
    response = github_api_request(uri)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      puts "Error fetching PR details for ##{pr_number}: #{response.code} #{response.message}"
      nil
    end
  rescue StandardError => e
    puts "Error fetching PR details for ##{pr_number}: #{e.message}"
    nil
  end

  def fetch_pr_reviews(repo_full_name, pr_number)
    uri = URI("#{GITHUB_API_BASE}/repos/#{repo_full_name}/pulls/#{pr_number}/reviews")
    response = github_api_request(uri)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      puts "Error fetching reviews for PR ##{pr_number}: #{response.code} #{response.message}"
      []
    end
  rescue StandardError => e
    puts "Error fetching reviews for PR ##{pr_number}: #{e.message}"
    []
  end

  def create_review_task(pr, review)
    repo_name = extract_repo_full_name(pr)
    pr_title = pr['title']
    pr_url = pr['html_url']
    pr_number = pr['number']
    reviewer = review['user']['login']
    review_state = review['state']

    # Map review state to readable format
    review_type = case review_state
                  when 'APPROVED'
                    'approval'
                  else
                    'review'
                  end

    task_content = "Follow up on #{review_type} of PR ##{pr_number}"
    task_description = "#{pr_url}\nPR: #{pr_title}\nRepository: #{repo_name}\nReview Type: #{review_type}\nReviewer: @#{reviewer}"

    uri = URI("#{TODOIST_API_BASE}/tasks")
    body = {
      content: task_content,
      description: task_description,
      priority: 4,
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

  def extract_repo_full_name(pr)
    pr['repository_url']&.split('/')&.last(2)&.join('/')
  end

  def github_api_request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@github_token}"
    request['Accept'] = 'application/vnd.github+json'
    request['X-GitHub-Api-Version'] = '2022-11-28'
    request['User-Agent'] = 'GitHub-Todoist-PR-Reviews'

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

  def load_state
    if File.exist?(STATE_FILE)
      JSON.parse(File.read(STATE_FILE))
    else
      { 'pr_reviews' => {} }
    end
  rescue StandardError => e
    puts "Warning: Could not load state file: #{e.message}"
    { 'pr_reviews' => {} }
  end

  def save_state
    # Ensure config directory exists
    FileUtils.mkdir_p(self.class.config_dir)
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

  sync = GithubTodoistPrReviews.new(
    github_token: github_token,
    todoist_token: todoist_token,
    todoist_project_id: todoist_project_id,
    todoist_section_id: todoist_section_id
  )

  sync.sync
end
