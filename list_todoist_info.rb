#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# Todoist Info Lister
# Lists projects and sections from your Todoist account
class TodoistInfoLister
  TODOIST_API_BASE = 'https://api.todoist.com/rest/v2'

  def initialize(todoist_token:)
    @todoist_token = todoist_token
  end

  def list_all
    puts "=" * 80
    puts "TODOIST PROJECTS AND SECTIONS"
    puts "=" * 80
    puts

    projects = fetch_projects

    if projects.empty?
      puts "No projects found."
      return
    end

    projects.each do |project|
      display_project(project)
      sections = fetch_sections(project['id'])

      if sections.empty?
        puts "  └─ (No sections)"
      else
        sections.each_with_index do |section, index|
          is_last = index == sections.length - 1
          prefix = is_last ? "  └─" : "  ├─"
          puts "#{prefix} Section: #{section['name']}"
          puts "  #{is_last ? ' ' : '│'}  ID: #{section['id']}"
        end
      end
      puts
    end

    puts "=" * 80
    puts "To use these IDs, add them to your .env file:"
    puts "  TODOIST_PROJECT_ID=<project_id>"
    puts "  TODOIST_SECTION_ID=<section_id>  # Optional"
    puts "=" * 80
  end

  def list_projects_only
    puts "=" * 80
    puts "TODOIST PROJECTS"
    puts "=" * 80
    puts

    projects = fetch_projects

    if projects.empty?
      puts "No projects found."
      return
    end

    projects.each do |project|
      display_project(project)
    end

    puts
    puts "=" * 80
    puts "To see sections for a project, run:"
    puts "  ruby list_todoist_info.rb sections <project_id>"
    puts "=" * 80
  end

  def list_sections(project_id)
    puts "=" * 80
    puts "SECTIONS FOR PROJECT ID: #{project_id}"
    puts "=" * 80
    puts

    sections = fetch_sections(project_id)

    if sections.empty?
      puts "No sections found for this project."
      return
    end

    sections.each do |section|
      puts "Section: #{section['name']}"
      puts "  ID: #{section['id']}"
      puts "  Order: #{section['order']}"
      puts
    end

    puts "=" * 80
    puts "To use this section, add to your .env file:"
    puts "  TODOIST_PROJECT_ID=#{project_id}"
    puts "  TODOIST_SECTION_ID=<section_id>"
    puts "=" * 80
  end

  private

  def display_project(project)
    is_inbox = project['inbox_project'] || false
    inbox_label = is_inbox ? " [INBOX]" : ""
    is_favorite = project['is_favorite'] || false
    fav_label = is_favorite ? " ⭐" : ""

    puts "Project: #{project['name']}#{inbox_label}#{fav_label}"
    puts "  ID: #{project['id']}"
    puts "  Color: #{project['color']}" if project['color']
  end

  def fetch_projects
    uri = URI("#{TODOIST_API_BASE}/projects")
    response = todoist_api_request(uri)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      puts "Error fetching projects: #{response.code} #{response.message}"
      puts response.body if response.body
      []
    end
  rescue StandardError => e
    puts "Error fetching projects: #{e.message}"
    []
  end

  def fetch_sections(project_id)
    uri = URI("#{TODOIST_API_BASE}/sections")
    params = { project_id: project_id }
    uri.query = URI.encode_www_form(params)

    response = todoist_api_request(uri)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      puts "Error fetching sections: #{response.code} #{response.message}"
      puts response.body if response.body
      []
    end
  rescue StandardError => e
    puts "Error fetching sections: #{e.message}"
    []
  end

  def todoist_api_request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@todoist_token}"

    http.request(request)
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

  todoist_token = ENV['TODOIST_TOKEN']

  if todoist_token.nil? || todoist_token.empty?
    puts "Error: TODOIST_TOKEN environment variable is required"
    puts "Please create a .env file with your TODOIST_TOKEN (see .env.example)"
    puts
    puts "Usage:"
    puts "  ruby list_todoist_info.rb [command] [args]"
    puts
    puts "Commands:"
    puts "  (none)              - List all projects with their sections"
    puts "  projects            - List only projects"
    puts "  sections PROJECT_ID - List sections for a specific project"
    exit 1
  end

  lister = TodoistInfoLister.new(todoist_token: todoist_token)

  command = ARGV[0]

  case command
  when 'projects'
    lister.list_projects_only
  when 'sections'
    project_id = ARGV[1]
    if project_id.nil? || project_id.empty?
      puts "Error: PROJECT_ID is required"
      puts "Usage: ruby list_todoist_info.rb sections PROJECT_ID"
      exit 1
    end
    lister.list_sections(project_id)
  when nil
    lister.list_all
  else
    puts "Error: Unknown command '#{command}'"
    puts
    puts "Available commands:"
    puts "  (none)              - List all projects with their sections"
    puts "  projects            - List only projects"
    puts "  sections PROJECT_ID - List sections for a specific project"
    exit 1
  end
end
