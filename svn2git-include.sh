#!/bin/bash

function error {
	echo
	echo "ERROR: $1"
	echo
	exit 1
}

function check_authors_file {
	if [ ! -e "$AUTHORS_FILE" ]
	then
		error "The authors file could not be found at $AUTHORS_FILE!"
	fi
}

function check_git_repo {
	if [ ! -d .git ]
	then
		error "Please create an intial Git repository and 'cd' into it."
	fi
}

function get_first_commit {
	git rev-list "$@" | tail -1
}


# transforms the log into the following format:
#   <gitSha1>
#   <svnRevision1>
#   <gitSha2>
#   <svnRevision2>
function parse_log {
	sed -n 's/^commit \(.*\)/\1/p; s/^\s*git-svn-id.*@\([0-9]\+\)\s.*/\1/p'
}

# find the SVN revision prior to the given revision searching the given branch
# @param: git_branch
# @param: svn_revision
function get_preceding_rev {
	# note the following command does not work: git svn find-rev -B "r$2" "$1"
	local revs=($(git log "$1" | parse_log))
	local nrevs=${#revs[@]}
	local -i i irev rev=$2
	# iterate over the different commits... every even entry refers to a git sha
	# and every uneven entry refers to a svn revision number (see parse_log)
	for ((i=1; i<nrevs; i+=2))
	do
			# irev is of type integer and >0 if the assigned value is an integer;
			# if irev==0, parsing to integer has failed
			irev=${revs[i]}
			if [ "$irev" -gt 0 -a "$irev" -lt "$rev" ]
			then
					echo "${revs[i-1]}"
					return 0
			fi
	done
}

function git_svn_fetch {
	while true; do
		# for large checkouts, it can happen that git-svn crashes
		# ... in this case we simply will call the command again
		git svn fetch "$@" && break
		if [ -e .git/gc.log ]
		then
			# too many unreferenced objects, call gc to clean up the objects
			git gc
			rm -f .git/gc.log
		fi
	done
}

# creates local branches using the function parameters as patterns
# which are passed over to 'grep' 
function create_local_branches {
	local refs_path=$1
	local branch_name_mapping=$2
	local ignore_paths=${3:-/^$/d}  # default: ignore empty lines

	git for-each-ref --format="%(refname)" "$refs_path" | sed "$ignore_paths" | (
		while read remote_branch
		do
			local_branch=$(echo "$remote_branch" | sed "$branch_name_mapping")
			git checkout -b "$local_branch" "$remote_branch"
		done
	)
}

# Rebase a whole git subtree.
# the main branch is rebased first in order to find all files which
# need to be removed before rebasing recursively all branches connected
# with the main branch 
function rebase {
	local branch=$1
	local upstream_branch=$2
	local split_at_svn_rev=$3
	local split_branch="${branch}-split"

	# split off before r22331 and remove deprecated packages
	split_commit=$(get_preceding_rev $upstream_branch $split_at_svn_rev) 
	git checkout -b "$split_branch" "$split_commit"

	# first rebase to figure out which files need to be deleted
	"$(dirname $0)/git-rebase-tree" "$split_branch" "$(get_first_commit "$branch")" "$branch"

	# remove all files that should not be copied to <branch>.
	# ... use git ls-tree with option "-z" to avoid encoding problems
	local backup_branch=$(git for-each-ref --format="%(refname)" refs/heads/backup | sed -n "s|refs/heads/\(.*/${branch}\)|\1|p")
	git checkout "$split_branch"
	"$(dirname $0)/git-trim-branch" "$backup_branch" "$branch"
	git commit --author='Univention GmbH <packages@univention.de>' -a -m "svn2git migration: remove files that have not been branched to $branch"

	# restore original branch and rebase _all_ connected branches
	git branch -M "$backup_branch" "$branch"
	"$(dirname $0)/git-rebase-tree" "$split_branch" "$(get_first_commit "$branch")" 
}

# make sure that committer == author for each commit
function rewrite_commits_with_author_info {
	branches=($(git branch -a | sed 's/^[ \*]*//; /backup/d'))
	git filter-branch -f --env-filter 'export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"; export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"; export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"' "${branches[@]}"
}

# rename all local branches given a regexp pattern
function rename_branches {
	local regexp=$1
	git for-each-ref --format="%(refname)" refs/heads | sed 's|^refs/heads/||; /^backup/d; /-split$/d;' | (
		while read branch
		do
			new_branch=$(echo "$branch" | sed "$regexp")
			echo "Renaming branch: $branch -> $new_branch"
			git branch -m "$branch" "$new_branch"
		done
	)
}

