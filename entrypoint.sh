#!/bin/sh

set -ux
##################################################################
urlencode() (
    i=1
    max_i=${#1}
    while test $i -le $max_i; do
        c="$(expr substr $1 $i 1)"
        case $c in
            [a-zA-Z0-9.~_-])
		printf "$c" ;;
            *)
		printf '%%%02X' "'$c" ;;
        esac
        i=$(( i + 1 ))
    done
)

##################################################################
DEFAULT_POLL_TIMEOUT=10
POLL_TIMEOUT=${POLL_TIMEOUT:-$DEFAULT_POLL_TIMEOUT}

echo "$(git status)"

if [ -n "${GITHUB_BASE_REF}" ]
then
  # get pull request information

  # the GITHUB_REF has the shape of refs/pull/<pr_number>/merge
  # split the variable by `/` and store the result as list
  splitted_github_ref=(${GITHUB_REF//// })
  # the PR number is stored on the 3rd position
  pr_id=${splitted_github_ref[2]}
  # compile the url for the api call to get the meta from the pull request
  pr_api_url=${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/pulls/${pr_id}

  curl --request GET --url "${pr_api_url}" --header "Accept: application/vnd.github+json" > pr.json
  head_clone_url=$(cat pr.json | jq -r .head.repo.clone_url)
  head_branch=$(cat pr.json | jq -r .head.ref)
  echo "HEAD url: $head_clone_url"
  echo "HEAD branch: $head_branch"

  git remote add head_repo $head_clone_url
  git fetch head_repo
  # checkout remote branch
  git checkout head_repo/$head_branch
  # set remote branch as local branch
  git checkout $head_branch

  # echo "Action triggered via pull request"
  # echo "GITHUB_BASE_REF -> ${GITHUB_BASE_REF}"
  # echo "GITHUB_HEAD_REF -> ${GITHUB_HEAD_REF}"
  
  # echo "GITHUB_REF_NAME -> ${GITHUB_REF_NAME}"
  # echo "GITHUB_REF_TYPE -> ${GITHUB_REF_TYPE}"
  # echo "GITHUB_SERVER_URL -> ${GITHUB_SERVER_URL}"
  # echo "GITHUB_REF_PROTECTED -> ${GITHUB_REF_PROTECTED}"
  # echo "GITHUB_PATH -> ${GITHUB_PATH}"
  
  # git checkout "${GITHUB_HEAD_REF}"
else
  echo "Action triggered via push"
  git checkout "${GITHUB_REF:11}"
fi

echo "{GITHUB_REF} -> ${GITHUB_REF}"
echo "{GITHUB_REF:11} -> ${GITHUB_REF:11}"

branch="$(git symbolic-ref --short HEAD)"
branch_uri="$(urlencode ${branch})"

sh -c "git config --global credential.username $GITLAB_USERNAME"
sh -c "git config --global core.askPass /cred-helper.sh"
sh -c "git config --global credential.helper cache"
sh -c "git remote add mirror $*"
sh -c "echo pushing to $branch branch at $(git remote get-url --push mirror)"
if [ "${FORCE_PUSH:-}" = "true" ]
then
  sh -c "git push --force mirror $branch"
else
  sh -c "git push mirror $branch"
fi

if [ "${FOLLOW_TAGS:-}" = "true" ]
then
  sh -c "echo pushing with --tags"
  sh -c "git push --tags mirror $branch"
fi

sleep $POLL_TIMEOUT

pipeline_id=$(curl --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" --silent "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/repository/commits/${branch_uri}" | jq '.last_pipeline.id')

echo "Triggered CI for branch ${branch}"
echo "Working with pipeline id #${pipeline_id}"
echo "Poll timeout set to ${POLL_TIMEOUT}"

ci_status="pending"

until [[ "$ci_status" != "pending" && "$ci_status" != "running" ]]
do
   sleep $POLL_TIMEOUT
   ci_output=$(curl --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" --silent "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/pipelines/${pipeline_id}")
   ci_status=$(jq -n "$ci_output" | jq -r .status)
   ci_web_url=$(jq -n "$ci_output" | jq -r .web_url)
   
   echo "Current pipeline status: ${ci_status}"
   if [ "$ci_status" = "running" ]
   then
     echo "Checking pipeline status..."
     curl -d '{"state":"pending", "target_url": "'${ci_web_url}'", "context": "gitlab-ci"}' -H "Authorization: token ${GITHUB_TOKEN}"  -H "Accept: application/vnd.github.antiope-preview+json" -X POST --silent "https://api.github.com/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}"  > /dev/null 
   fi
done

echo "Pipeline finished with status ${ci_status}"

echo "Fetching all GitLab pipeline jobs involved"
ci_jobs=$(curl --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" --silent "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/pipelines/${pipeline_id}/jobs" | jq -r '.[] | { id, name, stage }')
echo "Posting output from all GitLab pipeline jobs"
for JOB_ID in $(echo $ci_jobs | jq -r .id); do
  echo "##[group]Stage $( echo $ci_jobs | jq -r "select(.id=="$JOB_ID") | .stage" ) / Job $( echo $ci_jobs | jq -r "select(.id=="$JOB_ID") | .name" )"
  curl --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" --silent "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/jobs/${JOB_ID}/trace"
  echo "##[endgroup]"
done
echo "Debug problems by unfolding stages/jobs above"
  
if [ "$ci_status" = "success" ]
then 
  curl -d '{"state":"success", "target_url": "'${ci_web_url}'", "context": "gitlab-ci"}' -H "Authorization: token ${GITHUB_TOKEN}"  -H "Accept: application/vnd.github.antiope-preview+json" -X POST --silent "https://api.github.com/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}" 
  exit 0
elif [ "$ci_status" = "failed" ]
then 
  curl -d '{"state":"failure", "target_url": "'${ci_web_url}'", "context": "gitlab-ci"}' -H "Authorization: token ${GITHUB_TOKEN}"  -H "Accept: application/vnd.github.antiope-preview+json" -X POST --silent "https://api.github.com/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}" 
  exit 1
fi
