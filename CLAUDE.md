# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of Ruby-based GitHub-Todoist integrations. Each integration is a standalone script with no external gem dependencies (uses only Ruby stdlib). All integrations share common patterns and utilities.

**Current Integrations:**
- `github_todoist_combined.rb` - Combined script that runs both PR review requests sync and PR reviews sync in a single execution with shared API calls, request throttling, and rate limit monitoring

**Shared Utilities:**
- `list_todoist_info.rb` - Discovers Todoist project/section IDs for configuration

## Running Integrations

All scripts automatically read `.env` file - no manual export needed.

```bash
# Main sync script (runs both PR review requests and PR reviews)
ruby github_todoist_combined.rb

# Utility: List Todoist projects and sections
ruby list_todoist_info.rb
ruby list_todoist_info.rb projects
ruby list_todoist_info.rb sections <PROJECT_ID>
```

## Environment Configuration

All scripts automatically load `.env` file via shared `load_env_file()` function pattern.

**Shared variables:**
- `GITHUB_TOKEN` - GitHub Personal Access Token (needs `repo` or `public_repo` scope)
- `TODOIST_TOKEN` - Todoist API token
- `TODOIST_PROJECT_ID` - Target project (optional, defaults to Inbox)
- `TODOIST_SECTION_ID` - Target section within project (optional, requires project ID)
- `THROTTLE_DELAY_SECONDS` - Delay between API requests (optional, default 0.5s, combined script only)

Use `.env.example` as template. When adding new integrations, add integration-specific variables to `.env.example` with comments.

### Rate Limiting and Throttling

GitHub has two types of rate limits:
1. **Primary rate limit:** 5,000 requests/hour (generous, rarely hit)
2. **Secondary rate limit:** Triggered by burst patterns of rapid concurrent requests

The combined script addresses secondary rate limits through:
- **Request throttling:** Configurable delay between API requests (default 0.5s)
- **Shared PR details caching:** Eliminates duplicate fetches for the same PR
- **Sequential execution:** Prevents concurrent API bursts from multiple scripts
- **Rate limit monitoring:** Logs remaining quota and warns when approaching limits

If you experience rate limit errors (HTTP 429), increase `THROTTLE_DELAY_SECONDS` to 1.0 or higher.

## Shared Patterns

### Environment Loading

All scripts include identical `load_env_file()` function that:
- Reads `.env` from script's directory via `File.dirname(__FILE__)`
- Skips comments and empty lines
- Parses `KEY=VALUE` format
- Strips quotes from values
- Populates `ENV` hash

This enables shell-agnostic operation (works with bash, zsh, fish, etc.) and simpler cron setup. When creating new integrations, copy this function as-is.

### State Management Pattern

Integrations that need to track GitHub entities → Todoist tasks should:
- Store state in `~/.github_todoist_<integration>_state.json`
- Use JSON with mappings like `{"github_url": "todoist_task_id"}`
- Load state at init, persist after each sync
- Enable idempotent operation and automatic task lifecycle management

**Example (PR Review Requests Sync):**
```json
{
  "pr_to_task": {
    "https://github.com/owner/repo/pull/123": "todoist_task_id_string"
  }
}
```

**Example (PR Reviews Received Sync):**
```json
{
  "pr_reviews": {
    "https://github.com/owner/repo/pull/123": {
      "task_id": "todoist_task_id_string",
      "last_review_id": 123456790
    }
  }
}
```

This structure maintains **one task per PR**, tracking the latest review to determine when to update the task.

### Sync Flow Pattern

Standard pattern for bidirectional sync integrations:
1. **Fetch** - Get current items from GitHub (use Search API when possible)
2. **Create** - For new items not in state, create Todoist task and store mapping
3. **Complete** - For items in state but no longer active, close Todoist task and remove mapping
4. **Persist** - Save state JSON after each sync

**PR Reviews Sync Enhancement:**
The PR reviews integration extends this pattern with additional logic:
- Maintains **one task per PR** showing the most recent review
- Checks PR merge status via `pr_details['merged']`
- Checks for new review requests via `pr_details['requested_reviewers']`
- When a new review comes in, completes the old task and creates a new one
- Completes task when PR is merged, closed, or review is re-requested
- Tracks `last_review_id` to detect when a new review arrives

### API Integration

**GitHub API (base: `https://api.github.com`):**
- Prefer Search API (`/search/issues`) over specific endpoints for flexibility
- Standard headers: `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: GitHub-Todoist-Sync`
- Common search qualifiers: `type:pr`, `type:issue`, `state:open`, `review-requested:@me`, `assignee:@me`, `author:@me`
- Returns objects with `html_url` (use as unique identifier), `title`, `number`, `user`, `repository_url`
- PR details endpoint: `GET /repos/{owner}/{repo}/pulls/{number}` - Returns full PR object including `merged` status, `requested_reviewers`, `requested_teams`
- PR reviews endpoint: `GET /repos/{owner}/{repo}/pulls/{number}/reviews` - Returns array of review objects with `id`, `user`, `state` (APPROVED, CHANGES_REQUESTED, COMMENTED)

**Todoist API v2 (base: `https://api.todoist.com/rest/v2`):**
- REST endpoints, JSON payloads
- Standard headers: `Authorization: Bearer <token>`, `Content-Type: application/json`
- Create task: `POST /tasks` with `content` (required), `description`, `priority` (1-4), optional `project_id`/`section_id`
- Complete task: `POST /tasks/{id}/close` (returns 204 No Content)
- Get projects: `GET /projects`
- Get sections: `GET /sections?project_id=<id>`

## Adding New Integrations

When creating a new GitHub-Todoist integration:

1. **File naming:** `github_todoist_<feature>.rb`
2. **State file:** `~/.github_todoist_<feature>_state.json`
3. **Copy patterns:** Use `load_env_file()` function from existing scripts
4. **Class structure:** Single class with `initialize`, `sync`, and private helper methods
5. **API helpers:** Reuse `github_api_request` and `todoist_api_request` patterns
6. **Add to README:** Document the new integration with usage examples
7. **Update .env.example:** Add any integration-specific variables

## Customization

All customizations are done in `github_todoist_combined.rb`:

### PR Review Requests

**Task Priority** (line 408):
```ruby
priority: 4,  # 1=normal, 2=medium, 3=high, 4=urgent
```

**Task Format** (lines 155-156 in `create_todoist_task_for_review_request`):
```ruby
task_content = "Review PR ##{pr_number}: #{pr_title}"
task_description = "#{pr_url}\nRepository: #{repo_name}\nAuthor: @#{author}"
```

**Filtering:** Modify search query in `fetch_github_review_requests_search_only` to filter by repo/org

### PR Reviews Received

**Task Priority** (line 408):
```ruby
priority: 4,  # Can make dynamic: review_state == 'CHANGES_REQUESTED' ? 3 : 2
```

**Task Format** (lines 283-284 in `create_review_task`):
```ruby
task_content = "Follow up on #{review_type} of PR ##{pr_number}"
task_description = "#{pr_url}\nPR: #{pr_title}\nRepository: #{repo_name}\nReview Type: #{review_type}\nReviewer: @#{reviewer}"
```

**Filtering:** Modify review type handling in `create_review_task` to filter which reviews trigger tasks

### General

**Labels:** Add `labels: ['label-name']` to task body hash in `create_todoist_task` method

**Throttle Delay:** Adjust `THROTTLE_DELAY_SECONDS` in `.env` (default 0.5s, increase if experiencing rate limits)

## State File Management

State files live in home directory as `~/.github_todoist_<integration>_state.json`.

To reset an integration's state:
```bash
# PR Review Requests Sync
rm ~/.github_todoist_sync_state.json

# PR Reviews Received Sync
rm ~/.github_todoist_pr_reviews_state.json

# Generic pattern for future integrations
rm ~/.github_todoist_<feature>_state.json
```

Note: Resetting state won't clean up existing Todoist tasks, only the tracking mappings.

## Token Requirements

**GitHub Token Scopes:**
- `repo` - Full access to private repositories
- `public_repo` - Only public repositories (more restrictive option)

**Todoist Token:**
- Found at https://app.todoist.com/app/settings/integrations/developer
- Has full account access (Todoist doesn't support scoped tokens)

## Deployment

**Cron** (recommended interval: */10 to */15):
```cron
*/10 * * * * cd /path/to/repo && ruby github_todoist_combined.rb >> ~/github_todoist.log 2>&1
```

**Launchd** (macOS):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.github-todoist-combined</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ruby</string>
    <string>github_todoist_combined.rb</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/path/to/repo</string>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>StandardOutPath</key>
  <string>/tmp/github-todoist-combined.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/github-todoist-combined.err</string>
</dict>
</plist>
```

**Key requirement:** Script must run from repo directory (or have `WORKING_DIRECTORY` set) to find `.env` file via relative path resolution in `load_env_file()`.
