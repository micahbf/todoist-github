# GitHub-Todoist Integrations

A collection of Ruby scripts that automatically sync GitHub activities to Todoist tasks. No external gem dependencies - uses only Ruby stdlib.

## Features

**`github_todoist_combined.rb`** - Syncs both PR review requests and PR reviews in a single execution with optimizations to avoid rate limiting.

### PR Review Requests
- Automatically creates Todoist tasks for PRs requesting your review
- Includes PR title, repository, author, and URL in the task
- Sets tasks with configurable priority
- Automatically completes tasks when you finish the review
- Maintains state between runs to track which PRs have tasks

### PR Reviews Received
- Tracks reviews on all your open PRs
- Creates **one task per PR** showing the most recent review
- Updates the task when a new review comes in (completes old, creates new)
- Includes review type (Approval, Changes Requested, or Comments) in task
- Links directly to the PR for quick access
- **Automatically completes tasks when:**
  - The PR is merged
  - You request a new review (indicating you've addressed the feedback)
  - The PR is closed

### Performance & Reliability
- ✅ **Prevents rate limiting**: Throttles API requests and avoids concurrent bursts
- ✅ **More efficient**: Shares PR detail fetching between both syncs
- ✅ **Better monitoring**: Logs API usage and rate limit status
- ✅ **Configurable throttling**: Default 0.5s between API calls (adjustable)
- ✅ **Rate limit warnings**: Alerts when approaching limits
- ✅ **Safe to run repeatedly**: Idempotent operations

## Prerequisites

- Ruby (tested with Ruby 2.7+)
- GitHub Personal Access Token
- Todoist API Token

## Setup

### 1. Get Your GitHub Token

1. Go to https://github.com/settings/tokens
2. Click "Generate new token" (classic)
3. Give it a descriptive name like "Todoist PR Sync"
4. Select scopes:
   - `repo` (for private repositories)
   - OR `public_repo` (if you only need public repositories)
5. Click "Generate token" and copy it

### 2. Get Your Todoist Token

1. Go to https://app.todoist.com/app/settings/integrations/developer
2. Scroll down to "API token"
3. Copy your token

### 3. (Optional) Get Your Todoist Project ID and Section ID

The easiest way to find your project and section IDs is to use the included utility script:

```bash
# First, set up your .env file with at least TODOIST_TOKEN
cp .env.example .env
# Edit .env and add your TODOIST_TOKEN

# List all projects and their sections (reads .env automatically)
ruby list_todoist_info.rb

# Or list only projects
ruby list_todoist_info.rb projects

# Or list sections for a specific project
ruby list_todoist_info.rb sections 2331236912
```

**Alternative manual methods:**

If you want to find your project ID manually:
1. Open Todoist and navigate to the desired project
2. Look at the URL - it will be something like `https://todoist.com/app/project/2331236912`
3. The number at the end is your project ID

If you want to find section IDs using the API directly:
```bash
curl https://api.todoist.com/rest/v2/sections?project_id=YOUR_PROJECT_ID \
  -H "Authorization: Bearer YOUR_TODOIST_TOKEN"
```

### 4. Configure Environment Variables

Copy the example environment file:

```bash
cp .env.example .env
```

Edit `.env` and add your tokens:

```bash
GITHUB_TOKEN=ghp_your_token_here
TODOIST_TOKEN=your_todoist_token_here
TODOIST_PROJECT_ID=2331236912     # Optional
TODOIST_SECTION_ID=123456789      # Optional (requires project ID)
THROTTLE_DELAY_SECONDS=0.5        # Optional (for combined script, default 0.5)
```

## Usage

### Manual Run

The script automatically loads environment variables from the `.env` file:

```bash
ruby github_todoist_combined.rb
```

Or pass environment variables directly if preferred:

```bash
GITHUB_TOKEN=your_token TODOIST_TOKEN=your_token ruby github_todoist_combined.rb
```

### Automated Sync with Cron

To run the sync every 10-15 minutes:

1. Open your crontab:
   ```bash
   crontab -e
   ```

2. Add this line (adjust the path to your script location):
   ```cron
   */10 * * * * cd /Users/micahbf/code/github-todoist && ruby github_todoist_combined.rb >> ${XDG_CONFIG_HOME:-$HOME/.config}/github-todoist/github_todoist.log 2>&1
   ```

   Note: The script automatically reads the `.env` file, so no need to export variables in cron.

3. Save and exit

This will:
- Run every 10 minutes (adjust to */15 if preferred)
- Load environment variables from `.env`
- Throttle API requests to avoid rate limiting
- Log output to `$XDG_CONFIG_HOME/github-todoist/` (or `~/.config/github-todoist/` if XDG_CONFIG_HOME is not set)

### Using Launchd (macOS alternative to cron)

Create `~/Library/LaunchAgents/com.github.todoist.combined.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github.todoist.combined</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ruby</string>
        <string>/Users/micahbf/code/github-todoist/github_todoist_combined.rb</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/micahbf/code/github-todoist</string>
    <key>StartInterval</key>
    <integer>600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>~/.config/github-todoist/github_todoist_combined.log</string>
    <key>StandardErrorPath</key>
    <string>~/.config/github-todoist/github_todoist_combined.error.log</string>
</dict>
</plist>
```

Note: The script will automatically read the `.env` file from the WorkingDirectory, so you don't need to specify environment variables in the plist.

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/com.github.todoist.combined.plist
```

## How It Works

### PR Review Requests Sync

1. **Fetches Review Requests**: Uses GitHub's search API with `review-requested:@me` to find all open PRs where you're requested as a reviewer

2. **Creates Tasks**: For each PR requesting review, creates a Todoist task with:
   - Content: "Review PR #123: Fix authentication bug"
   - Description: Repository name, author, and PR URL
   - Priority: Normal (1)
   - Project: Your specified project or Inbox
   - Section: Your specified section (if configured)

3. **Tracks State**: Maintains a mapping of PR URLs to Todoist task IDs in `~/.github_todoist_sync_state.json`

4. **Completes Tasks**: When a PR no longer appears in your review requests (because you reviewed it or the request was removed), the corresponding Todoist task is automatically marked complete

### PR Reviews Received Sync

1. **Fetches Your PRs**: Uses GitHub's search API with `author:@me` to find all open PRs you created

2. **Checks for Reviews**: For each PR, fetches all submitted reviews using the GitHub API

3. **Creates/Updates Follow-up Tasks**: For each PR with reviews, maintains **one task per PR**:
   - Shows the most recent review
   - When a new review comes in, completes the old task and creates a new one
   - Content: "Follow up on [Review Type] from @reviewer - PR #123"
   - Description: PR title, repository, review type, reviewer, and PR URL
   - Priority: High (3) for "Changes Requested", Medium (2) for others
   - Project: Your specified project or Inbox
   - Section: Your specified section (if configured)

4. **Tracks State**: Maintains a mapping of PR URLs to task IDs and last review IDs in `~/.github_todoist_pr_reviews_state.json`

5. **Completes Tasks Automatically**:
   - When PR is merged, completes the review follow-up task
   - When new review is requested (checked via `requested_reviewers` field), completes the existing task
   - When PR is closed, completes task and removes from tracking
   - When a new review comes in, completes the old task before creating the updated one

6. **Cleans Up**: Removes closed/merged PRs from tracking state

## Task Format

### Review Request Tasks

```
Review PR #123: Fix authentication bug

Repository: owner/repo-name
Author: @username
URL: https://github.com/owner/repo-name/pull/123
```

### Review Received Tasks

```
Follow up on Changes Requested from @reviewer - PR #123

PR: Fix authentication bug
Repository: owner/repo-name
Review Type: Changes Requested
Reviewer: @reviewer
URL: https://github.com/owner/repo-name/pull/123
```

## Troubleshooting

### "Error: GITHUB_TOKEN environment variable is required"

Make sure you've set the environment variables. If using a `.env` file, load it with:
```bash
export $(cat .env | xargs)
```

### "Error fetching GitHub PRs: 401"

Your GitHub token is invalid or expired. Generate a new one.

### "Error creating Todoist task: 401"

Your Todoist token is invalid. Get a new one from the Todoist integrations page.

### Tasks aren't being created

1. Check that you actually have PR review requests: https://github.com/pulls/review-requested
2. Run the script with verbose output to see what's happening
3. Check the log file if running via cron

### Rate limit errors (HTTP 429)

If you're experiencing rate limit errors:

1. **Switch to the combined script** (`github_todoist_combined.rb`) - it includes throttling to avoid rate limits
2. **Increase throttle delay** - Set `THROTTLE_DELAY_SECONDS=1.0` (or higher) in your `.env` file
3. **Reduce sync frequency** - Change cron from */10 to */15 or */20
4. **Check rate limit status** - The combined script logs your remaining API quota when it's below 50%

### State file and log locations

All artifacts (state files and logs) are stored in `$XDG_CONFIG_HOME/github-todoist/` (or `~/.config/github-todoist/` if XDG_CONFIG_HOME is not set):

**State files:**
- `github_todoist_sync_state.json` - PR review requests tracking
- `github_todoist_pr_reviews_state.json` - PR reviews received tracking

**Log files (when using cron or launchd):**
- `github_todoist_sync.log` - Output from PR review requests sync
- `github_todoist_pr_reviews.log` - Output from PR reviews received sync

You can delete the state files to reset the state, but existing tasks won't be automatically cleaned up.

## Security Notes

- Keep your `.env` file secure and never commit it to version control
- The `.gitignore` file is configured to exclude `.env` and the state file
- Both tokens have significant permissions - treat them like passwords
- Consider using a GitHub fine-grained token with minimal permissions if available

## Utility Scripts

### list_todoist_info.rb

A helper script to easily find your Todoist project and section IDs.

**Usage:**

```bash
# List all projects with their sections (default)
# The script automatically reads .env file
ruby list_todoist_info.rb

# List only projects
ruby list_todoist_info.rb projects

# List sections for a specific project
ruby list_todoist_info.rb sections <PROJECT_ID>
```

**Example output:**

```
================================================================================
TODOIST PROJECTS AND SECTIONS
================================================================================

Project: Work [INBOX]
  ID: 2331236912
  Color: charcoal
  └─ (No sections)

Project: Personal ⭐
  ID: 2331236913
  Color: blue
  ├─ Section: Important
  │  ID: 123456789
  └─ Section: Later
     ID: 123456790

================================================================================
To use these IDs, add them to your .env file:
  TODOIST_PROJECT_ID=<project_id>
  TODOIST_SECTION_ID=<section_id>  # Optional
================================================================================
```

## Customization

Edit `github_todoist_combined.rb` to customize:

### PR Review Requests

- **Task priority** (line 408): `priority: 4` (1=normal, 2=medium, 3=high, 4=urgent)
- **Task format** (lines 155-156): Customize task content and description
- **Filtering**: Modify search query in `fetch_github_review_requests_search_only` to filter by repo/org
- **Labels**: Add `labels: ['label-name']` to task body hash in `create_todoist_task`

### PR Reviews Received

- **Task priority** (line 408): `priority: 4` (can make dynamic based on review type)
- **Task format** (lines 283-284): Customize task content and description
- **Filtering**: Modify review type handling in `create_review_task` to filter which reviews trigger tasks
- **Labels**: Add `labels: ['label-name']` to task body hash in `create_todoist_task`

### Rate Limiting

- **Throttle delay**: Set `THROTTLE_DELAY_SECONDS` in `.env` (default 0.5s, increase if experiencing rate limits)

## License

MIT
