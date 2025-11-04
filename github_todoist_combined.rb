#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'fileutils'
require 'date'
require 'set'

# Combined GitHub-Todoist Sync
# Syncs both PR review requests AND PR reviews in a single execution
# This reduces concurrent API requests and shares PR detail fetching
class GithubTodoistCombined
  GITHUB_API_BASE = 'https://api.github.com'
  TODOIST_API_BASE = 'https://api.todoist.com/rest/v2'

  def self.config_dir
    xdg_config = ENV['XDG_CONFIG_HOME'] || File.expand_path('~/.config')
    File.join(xdg_config, 'github-todoist')
  end

  SYNC_STATE_FILE = File.join(config_dir, 'github_todoist_sync_state.json')
  REVIEWS_STATE_FILE = File.join(config_dir, 'github_todoist_pr_reviews_state.json')

  def initialize(github_token:, todoist_token:, todoist_project_id: nil, todoist_section_id: nil, throttle_delay: 0.5)
    @github_token = github_token
    @todoist_token = todoist_token
    @todoist_project_id = todoist_project_id
    @todoist_section_id = todoist_section_id
    @throttle_delay = throttle_delay.to_f

    # Load separate state files for each sync type
    @sync_state = load_state(SYNC_STATE_FILE, { 'pr_to_task' => {} })
    @reviews_state = load_state(REVIEWS_STATE_FILE, { 'pr_reviews' => {} })

    # Cache for PR details to avoid duplicate fetches
    @pr_details_cache = {}

    @user_login = nil
    @api_call_count = 0
  end

  def sync
    puts "=" * 60
    puts "Starting Combined GitHub-Todoist Sync"
    puts "=" * 60
    puts ""

    start_time = Time.now

    # Run both syncs
    sync_review_requests
    puts ""
    sync_pr_reviews

    # Save both state files
    save_state(SYNC_STATE_FILE, @sync_state)
    save_state(REVIEWS_STATE_FILE, @reviews_state)

    elapsed = (Time.now - start_time).round(2)
    puts ""
    puts "=" * 60
    puts "Sync completed successfully in #{elapsed}s"
    puts "Total API calls made: #{@api_call_count}"
    puts "=" * 60
  end

  private

  # ============================================================================
  # PR Review Requests Sync (from github_todoist_sync.rb)
  # ============================================================================

  def sync_review_requests
    puts "--- Syncing PR Review Requests ---"

    # Fetch PRs requesting review (search API only, no filtering yet)
    all_review_requests = fetch_github_review_requests_search_only

    # If nil is returned, there was an API error - abort sync to avoid false completions
    if all_review_requests.nil?
      puts "Aborting review requests sync due to API error"
      return
    end

    puts "Found #{all_review_requests.length} PR(s) requesting review (may include team requests)"

    # Only fetch PR details for PRs not yet in our state
    # (PRs already in state have been validated as direct requests previously)
    new_prs = all_review_requests.reject { |pr| @sync_state['pr_to_task'].key?(pr['html_url']) }
    existing_pr_urls = all_review_requests.select { |pr| @sync_state['pr_to_task'].key?(pr['html_url']) }.map { |pr| pr['html_url'] }.to_set

    puts "#{new_prs.length} new PR(s) to validate, #{existing_pr_urls.size} already tracked"

    # Validate new PRs to check if directly requested
    directly_requested_new_prs = new_prs.select { |pr| directly_requested_reviewer?(pr) }
    puts "#{directly_requested_new_prs.length} new PR(s) where you are directly requested"

    # Create tasks for new PRs where directly requested
    directly_requested_new_prs.each do |pr|
      pr_url = pr['html_url']
      task_id = create_todoist_task_for_review_request(pr)
      if task_id
        @sync_state['pr_to_task'][pr_url] = task_id
        puts "Created task for PR: #{pr_url}"
      end
    end

    # Build set of all current PR URLs (both new direct requests and existing tracked)
    current_pr_urls = existing_pr_urls + directly_requested_new_prs.map { |pr| pr['html_url'] }

    # Complete tasks for PRs no longer requesting review
    @sync_state['pr_to_task'].dup.each do |pr_url, task_id|
      next if current_pr_urls.include?(pr_url)

      if complete_todoist_task(task_id)
        @sync_state['pr_to_task'].delete(pr_url)
        puts "Completed task for PR: #{pr_url}"
      end
    end

    puts "Review requests sync completed"
  end

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
      # Return nil on error to signal API failure (vs legitimately 0 results)
      # This prevents false completions when rate limited or other errors occur
      puts "Error fetching GitHub PRs: #{response.code} #{response.message}"
      puts response.body if response.body
      nil
    end
  rescue StandardError => e
    puts "Error fetching GitHub PRs: #{e.message}"
    nil
  end

  def directly_requested_reviewer?(pr)
    # Extract repo owner and name from PR URL or repository_url
    repo_full_name = pr['repository_url']&.split('/')&.last(2)&.join('/')
    return false unless repo_full_name

    pr_number = pr['number']
    return false unless pr_number

    # Fetch full PR details to check requested_reviewers (uses cache)
    pr_details = fetch_pr_details(repo_full_name, pr_number)
    return true unless pr_details # If we can't fetch details, err on the side of inclusion

    requested_reviewers = pr_details['requested_reviewers'] || []

    # Get the authenticated user's login
    user_login = get_authenticated_user_login

    # Check if the authenticated user is in the requested_reviewers array
    requested_reviewers.any? { |reviewer| reviewer['login'] == user_login }
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

  def create_todoist_task_for_review_request(pr)
    repo_name = pr['repository_url']&.split('/')&.last(2)&.join('/') || 'Unknown repo'
    pr_title = pr['title']
    pr_url = pr['html_url']
    pr_number = pr['number']
    author = pr['user']['login']

    task_content = "Review PR ##{pr_number}: #{pr_title}"
    task_description = "#{pr_url}\nRepository: #{repo_name}\nAuthor: @#{author}"

    create_todoist_task(task_content, task_description)
  end

  # ============================================================================
  # PR Reviews Sync (from github_todoist_pr_reviews.rb)
  # ============================================================================

  def sync_pr_reviews
    puts "--- Syncing PR Reviews ---"

    # Fetch all open PRs authored by me
    my_open_prs = fetch_my_open_prs

    # If nil is returned, there was an API error - abort sync to avoid false completions
    if my_open_prs.nil?
      puts "Aborting PR reviews sync due to API error"
      return
    end

    puts "Found #{my_open_prs.length} open PR(s) authored by you"

    # Track which PRs are still open
    current_pr_urls = my_open_prs.map { |pr| pr['html_url'] }.to_set

    # For each PR, check for reviews and process
    my_open_prs.each do |pr|
      process_pr(pr)
    end

    # Complete tasks for PRs that are no longer open (closed or merged)
    @reviews_state['pr_reviews'].keys.each do |tracked_pr_url|
      unless current_pr_urls.include?(tracked_pr_url)
        complete_task_for_pr(tracked_pr_url, "PR is no longer open")
        @reviews_state['pr_reviews'].delete(tracked_pr_url)
        puts "Removed closed/merged PR from tracking: #{tracked_pr_url}"
      end
    end

    puts "PR reviews sync completed"
  end

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
      # Return nil on error to signal API failure (vs legitimately 0 results)
      # This prevents false completions when rate limited or other errors occur
      puts "Error fetching GitHub PRs: #{response.code} #{response.message}"
      puts response.body if response.body
      nil
    end
  rescue StandardError => e
    puts "Error fetching GitHub PRs: #{e.message}"
    nil
  end

  def process_pr(pr)
    pr_url = pr['html_url']
    repo_full_name = extract_repo_full_name(pr)
    return unless repo_full_name

    pr_number = pr['number']
    return unless pr_number

    # Fetch full PR details to check merge status and review requests (uses cache)
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
    @reviews_state['pr_reviews'][pr_url] ||= { 'task_id' => nil, 'last_review_id' => nil }

    # Get the most recent review (reviews are returned chronologically)
    latest_review = reviews.last

    # Check if this is a new review or if we don't have a task yet
    if @reviews_state['pr_reviews'][pr_url]['last_review_id'] != latest_review['id']
      # Complete old task if it exists and create new task for this review
      complete_task_for_pr(pr_url, "New review received") if @reviews_state['pr_reviews'][pr_url]['task_id']

      # Create task for this PR
      task_id = create_review_task(pr, latest_review)
      if task_id
        @reviews_state['pr_reviews'][pr_url]['task_id'] = task_id
        @reviews_state['pr_reviews'][pr_url]['last_review_id'] = latest_review['id']
        puts "Created/updated follow-up task for PR: #{pr_url}"
      end
    end
  end

  def complete_task_for_pr(pr_url, reason)
    return unless @reviews_state['pr_reviews'][pr_url]

    task_id = @reviews_state['pr_reviews'][pr_url]['task_id']
    return unless task_id

    if complete_todoist_task(task_id)
      puts "Completed task for PR #{pr_url}: #{reason}"
      @reviews_state['pr_reviews'][pr_url]['task_id'] = nil
    end
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

    create_todoist_task(task_content, task_description)
  end

  def extract_repo_full_name(pr)
    pr['repository_url']&.split('/')&.last(2)&.join('/')
  end

  # ============================================================================
  # Shared Utilities
  # ============================================================================

  def fetch_pr_details(repo_full_name, pr_number)
    # Use cache to avoid duplicate fetches for the same PR
    cache_key = "#{repo_full_name}##{pr_number}"
    return @pr_details_cache[cache_key] if @pr_details_cache.key?(cache_key)

    uri = URI("#{GITHUB_API_BASE}/repos/#{repo_full_name}/pulls/#{pr_number}")
    response = github_api_request(uri)

    if response.is_a?(Net::HTTPSuccess)
      pr_details = JSON.parse(response.body)
      @pr_details_cache[cache_key] = pr_details
      pr_details
    else
      puts "Error fetching PR details for ##{pr_number}: #{response.code} #{response.message}"
      nil
    end
  rescue StandardError => e
    puts "Error fetching PR details for ##{pr_number}: #{e.message}"
    nil
  end

  def create_todoist_task(task_content, task_description)
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
    # Throttle requests to avoid secondary rate limits
    sleep(@throttle_delay) if @api_call_count > 0

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@github_token}"
    request['Accept'] = 'application/vnd.github+json'
    request['X-GitHub-Api-Version'] = '2022-11-28'
    request['User-Agent'] = 'GitHub-Todoist-Combined'

    @api_call_count += 1
    response = http.request(request)

    # Log rate limit info
    log_rate_limit_info(response)

    response
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

  def log_rate_limit_info(response)
    return unless response['X-RateLimit-Limit']

    limit = response['X-RateLimit-Limit'].to_i
    remaining = response['X-RateLimit-Remaining'].to_i
    reset_time = Time.at(response['X-RateLimit-Reset'].to_i)
    used_percent = ((limit - remaining) / limit.to_f * 100).round(1)

    # Only log if we're using more than 50% of the rate limit
    if used_percent > 50
      puts "  [Rate Limit] #{remaining}/#{limit} remaining (#{used_percent}% used), resets at #{reset_time.strftime('%H:%M:%S')}"
    end

    # Warn if getting close to limit
    if remaining < 100
      puts "  WARNING: Only #{remaining} API calls remaining until #{reset_time.strftime('%H:%M:%S')}"
    end
  end

  def load_state(file_path, default_state)
    if File.exist?(file_path)
      JSON.parse(File.read(file_path))
    else
      default_state
    end
  rescue StandardError => e
    puts "Warning: Could not load state file #{file_path}: #{e.message}"
    default_state
  end

  def save_state(file_path, state_data)
    # Ensure config directory exists
    FileUtils.mkdir_p(self.class.config_dir)
    File.write(file_path, JSON.pretty_generate(state_data))
  rescue StandardError => e
    puts "Error saving state file #{file_path}: #{e.message}"
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
  throttle_delay = ENV['THROTTLE_DELAY_SECONDS'] || '0.5' # Optional, default 0.5s

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

  sync = GithubTodoistCombined.new(
    github_token: github_token,
    todoist_token: todoist_token,
    todoist_project_id: todoist_project_id,
    todoist_section_id: todoist_section_id,
    throttle_delay: throttle_delay
  )

  sync.sync
end
