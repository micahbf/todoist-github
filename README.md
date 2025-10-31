# GitHub-Todoist Integrations

A collection of Ruby scripts that automatically sync GitHub activities to Todoist tasks. No external gem dependencies - uses only Ruby stdlib.

## Integrations

### 1. PR Review Requests Sync (`github_todoist_sync.rb`)
Syncs GitHub pull request review requests to Todoist tasks. When you're requested to review a PR, a task is created in Todoist. When you complete the review (or the request is removed), the task is automatically marked as complete.

**Features:**
- Automatically creates Todoist tasks for PRs requesting your review
- Includes PR title, repository, author, and URL in the task
- Sets tasks with configurable priority
- Automatically completes tasks when you finish the review
- Maintains state between runs to track which PRs have tasks
- Safe to run repeatedly (idempotent)

### 2. PR Reviews Received Sync (`github_todoist_pr_reviews.rb`)
Monitors your own PRs for new reviews and creates follow-up tasks. When someone reviews your PR, a task is created with details about the latest review.

**Features:**
- Tracks reviews on all your open PRs
- Creates **one task per PR** showing the most recent review
- Updates the task when a new review comes in (completes old, creates new)
- Includes review type (Approval, Changes Requested, or Comments) in task
- Sets higher priority for "Changes Requested" reviews
- Links directly to the PR for quick access
- **Automatically completes tasks when:**
  - The PR is merged
  - You request a new review (indicating you've addressed the feedback)
  - The PR is closed

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
TODOIST_PROJECT_ID=2331236912  # Optional
TODOIST_SECTION_ID=123456789   # Optional (requires project ID)
```

## Usage

### Manual Run

The scripts automatically load environment variables from the `.env` file:

```bash
# PR Review Requests Sync
ruby github_todoist_sync.rb

# PR Reviews Received Sync
ruby github_todoist_pr_reviews.rb
```

Or pass environment variables directly if preferred:

```bash
GITHUB_TOKEN=your_token TODOIST_TOKEN=your_token ruby github_todoist_sync.rb
GITHUB_TOKEN=your_token TODOIST_TOKEN=your_token ruby github_todoist_pr_reviews.rb
```

### Automated Sync with Cron

To run the syncs automatically every 15 minutes:

1. Open your crontab:
   ```bash
   crontab -e
   ```

2. Add these lines (adjust the path to your script location):
   ```cron
   */15 * * * * cd /Users/micahbf/code/github-todoist && ruby github_todoist_sync.rb >> ${XDG_CONFIG_HOME:-$HOME/.config}/github-todoist/github_todoist_sync.log 2>&1
   */15 * * * * cd /Users/micahbf/code/github-todoist && ruby github_todoist_pr_reviews.rb >> ${XDG_CONFIG_HOME:-$HOME/.config}/github-todoist/github_todoist_pr_reviews.log 2>&1
   ```

   Note: The scripts automatically read the `.env` file, so no need to export variables in cron.

3. Save and exit

This will:
- Run every 15 minutes
- Load environment variables from `.env`
- Log output to `$XDG_CONFIG_HOME/github-todoist/` (or `~/.config/github-todoist/` if XDG_CONFIG_HOME is not set)

### Using Launchd (macOS alternative to cron)

Create separate plist files for each integration.

For PR Review Requests (`~/Library/LaunchAgents/com.github.todoist.sync.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github.todoist.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ruby</string>
        <string>/Users/micahbf/code/github-todoist/github_todoist_sync.rb</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/micahbf/code/github-todoist</string>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>~/.config/github-todoist/github_todoist_sync.log</string>
    <key>StandardErrorPath</key>
    <string>~/.config/github-todoist/github_todoist_sync.error.log</string>
</dict>
</plist>
```

For PR Reviews Received (`~/Library/LaunchAgents/com.github.todoist.pr_reviews.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github.todoist.pr_reviews</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ruby</string>
        <string>/Users/micahbf/code/github-todoist/github_todoist_pr_reviews.rb</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/micahbf/code/github-todoist</string>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>~/.config/github-todoist/github_todoist_pr_reviews.log</string>
    <key>StandardErrorPath</key>
    <string>~/.config/github-todoist/github_todoist_pr_reviews.error.log</string>
</dict>
</plist>
```

Note: The scripts will automatically read the `.env` file from the WorkingDirectory, so you don't need to specify environment variables in the plist.

Then load them:

```bash
launchctl load ~/Library/LaunchAgents/com.github.todoist.sync.plist
launchctl load ~/Library/LaunchAgents/com.github.todoist.pr_reviews.plist
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

### PR Review Requests Sync (`github_todoist_sync.rb`)

- Change task priority (line 156): `priority: 1` (1=normal, 2=medium, 3=high, 4=urgent)
- Customize task content format (lines 149-150)
- Add labels to tasks by modifying the `body` hash in `create_todoist_task`
- Filter PRs by repository or other criteria in `fetch_github_review_requests_search_only`

### PR Reviews Received Sync (`github_todoist_pr_reviews.rb`)

- Change task priority (line 206): `priority: review_state == 'CHANGES_REQUESTED' ? 3 : 2`
- Customize task content format (line 190)
- Add labels to tasks by modifying the `body` hash in `create_or_update_review_task`
- Filter which review types trigger tasks by modifying the review processing logic

## License

MIT
