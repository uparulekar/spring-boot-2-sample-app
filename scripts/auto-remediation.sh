run-cra-bom() {
  local url=$1          # git url of the repo
  local path=$2         # path where the repo has been cloned
  local repo_key=$3     # key to reference other elements while using load_repo
  local output=$4       # path to the generated bom file

  local exit_code status

  ibmcloud_login

  report_names="${output}"
  local params=(
    --asset-type "apps" \
    --path "${WORKSPACE}/${path}" \
    --report "${report_names}" \
    --region "$(get_env TOOLCHAIN_REGION "")"
  )

  ibmcloud cra bom-generate "${params[@]}" >&2

  exit_code=$?

  status="success"

  if [ $exit_code -ne 0 ]; then
    status="failure"
  fi

  cd "$WORKSPACE" || exit 1

  if [ "${status}" == "success" ]; then
    return 0
  else
    return 1
  fi
}

run-cra-vulnerability-scan_old() {
  local path=$1
  local bom_path=$2

  local output
  output="cra_vulnerability.json"

  cd "$WORKSPACE/$path" || exit 1

  echo "Run CRA Vulnerability scan on"

  local params=(
    --strict \
    --bom "${bom_path}" \
    --region "$(get_env TOOLCHAIN_REGION "")"
  )

  ibmcloud cra cve --report ${output} "${params[@]}" >&2
}

### Assumptions
# 1. This code runs npm install for nodejs. 
#     a. The user needs to update the CRA_CUSTOM_SCRIPT_PATH, add supporting setup related to it.
#     b. Needs to ensure that updated .npmrc is available.
# 3. Currently works in CC pipeline only. It creates a new branch and a new PR
# 4. Currently this function only works for enterprise github and gitlab
run-cra-auto-remediation() {
  local url=$1          # git url of the repo
  local path=$2         # path where the repo has been cloned
  local repo_key=$3     # key to reference other elements while using load_repo
  local bom_path=$4     # path to the generated bom file

  local autofixflag=$(get_env opt-in-cra-auto-remediation "false")
  if [ "${autofixflag}" == "false" ]; then
    echo
    echo "CRA auto remediation is turned off. To enable it, set the value of environment variable opt-in-cra-auto-remediation to true"
    exit 0
  fi

  set -x
  local enabledrepos=$(get_env opt-in-cra-auto-remediation-enabled-repos "")
  if [ -z "${enabledrepos}" ]; then
    echo
    echo "The environment variable opt-in-cra-auto-remediation-enabled_repos is not set. CRA Auto remediation is therefore enabled for all the repos."
    echo "To enable CRA Auto remediation for a specific repo, add the repo name as a comma separated value to the environment variable opt-in-cra-auto-remediation-enabled_repos."
  fi

  local pipeline_namespace=$(get_env pipeline_namespace)
  if [ "$pipeline_namespace" != "cc" ]; then
    echo
    echo "${pipeline_namespace} detected. CRA Auto remediation works only in the CC pipeline."
    exit 0
  fi

  cd "$WORKSPACE/$path" || exit 1

  local target_branch=$(git-get-default-branch)
  if [ -z "${target_branch}" ]; then
    echo "CRA Auto remediation: Failed to get default branch for this repo.  exiting CRA Auto remediation"
    exit 1
  fi

  local exit_code=0
  local pr_number
  local project_id
  local output=$(mktemp /tmp/cra_vulnerability_XXXXXX.json)
  local autofixcommentfile=$(mktemp /tmp/autofix_comment_XXXXXX.md)
  local source_branch="cra_auto_remediation"
  local pr_number="0"
  local files_added="false"

  #local scm_type=$(get_absolute_scm_type $url)
  #local scm_type="hostedgit"
  local scm_type="github_integrated"
  
  local hostname=$(echo $url | awk -F/ '{print $3}')
  local owner=$(echo $url | awk -F/ '{print $4}')
  local repo=$(echo $url | awk -F/ '{print $5}')

  local enabled=$(is-repo-enabled-for-auto-remediation $repo)
  if [ "${enabled}" == "false" ]; then
    echo
    echo "CRA Auto remediation is not enabled for this repo. Add this repo name as a comma separated value to the environment variable opt-in-cra-auto-remediation-enabled_repos"
    exit 0
  fi

  echo "Run CRA Auto Remediation..."
  local newparams=(
    --bom "${bom_path}" \
    --region "$(get_env TOOLCHAIN_REGION "")" \
    --autofix \
    --path "${WORKSPACE}/${path}" \
    --commentfile ${autofixcommentfile}
  )

  local autofix_force=$(get_env opt-in-cra-auto-remediation-force "false")
  if [ "${autofix_force}" == "true" ]; then
    newparams+=("--force")
  fi

  ibmcloud cra cve --report ${output} "${newparams[@]}" >&2

  # determine if relavent files had changed
  if [ $(num-relevant-files-changed) -ne 0 ]; then
    # commit the changes for these two files to the existing PR
    git config user.name "CRA Autoremediation"
    git config --global user.email autoremediation@ibm.com

    APP_TOKEN_PATH="$WORKSPACE/auto-remediation-git-token"
    #get_repo_token $url $APP_TOKEN_PATH
    cat "$WORKSPACE/git-token" > "$WORKSPACE/auto-remediation-git-token"

    # create a new branch, if it does not exist
    b_exist=$(git branch -r | grep "${source_branch}" | wc -l)
    if [ ${b_exist} -eq 0 ]; then
      git checkout -b "${source_branch}"
    else
      git stash     # to deal with existing changes not yet merged
      git checkout "${source_branch}"
      git pull --no-edit origin "${source_branch}"
      git stash pop
    fi

    if [ $(num-file-modified "package.json") -eq 1 ]; then
      git add $(git status -s -uno | grep "package.json" | awk '{print $2}')
      files_added="true"
    fi
    if [ $(num-file-modified "package-lock.json") -eq 1 ]; then
      git add $(git status -s -uno | grep "package-lock.json" | awk '{print $2}')
      files_added="true"
    fi
    if [ $(num-file-modified "build.gradle") -eq 1 ]; then
      git add $(git status -s -uno | grep "build.gradle" | awk '{print $2}')
      files_added="true"
    fi
    if [ $(num-file-modified "gradle.lockfile") -eq 1 ]; then
      git add $(git status -s -uno | grep "gradle.lockfile" | awk '{print $2}')
      files_added="true"
    fi
    if [ $(num-file-modified "buildscript-gradle.lockfile") -eq 1 ]; then
      git add $(git status -s -uno | grep "buildscript-gradle.lockfile" | awk '{print $2}')
      files_added="true"
    fi
    if [ $(num-file-modified "pom.xml") -eq 1 ]; then
      git add $(git status -s -uno | grep "pom.xml" | awk '{print $2}')
      files_added="true"
    fi

    if [ "${files_added}" == "true" ]; then
      echo "CRA Auto remediation: performing git commit..."
      git commit --allow-empty -m "CRA auto-remediation updates"

      git push -u origin "${source_branch}"

      # create a PR or MR
      if [ $scm_type == "github_integrated" ]; then   # Enterprise github
        pr_number=$(github-integrated-get-existing-pr ${hostname} ${owner} ${repo} ${source_branch} ${target_branch})
        if [ "${pr_number}" == "0" ]; then
          github-integrated-create-pr ${hostname} ${owner} ${repo} ${source_branch} ${target_branch} ${autofixcommentfile}
        else
          echo "No new pull request was created as a PR - ${url}/pull/${pr_number} exists, waiting to be merged"
        fi
      elif [ $scm_type == "hostedgit" ]; then         # gitlab
        project_id=$(hostedgit-get-project-id ${hostname} ${url})
        pr_number=$(hostedgit-get-existing-mr ${hostname} ${project_id} ${source_branch} ${target_branch})
        if [ "${pr_number}" == "0" ]; then
          hostedgit-create-mr ${hostname} ${project_id} ${autofixcommentfile} ${source_branch} ${target_branch}
        else
          echo "No new merge request was created as a MR - ${url}/-/merge_request/${pr_number} exists, waiting to be merged"
        fi
      else
        echo "CRA Auto remediation: Unsupported SCM type, could not create a pull request"
      fi
    fi

    # revert back to HEAD branch for further processing, in CC pipeline tshe above processing is in different branch
    commit_sha="$(load_repo "${repo_key}" commit)"
    git checkout $commit_sha

  else
    echo
    echo "No code updates were made by CRA auto remediation tool"
    echo
  fi

  if [ "${pr_number}" != "0" ]; then
    if [ $scm_type == "github_integrated" ]; then 
      github-integrated-add-comment-to-pr ${hostname} ${owner} ${repo} ${pr_number} ${autofixcommentfile}
    elif [ $scm_type == "hostedgit" ]; then
      hostedgit-add-comment-to-mr ${hostname} ${project_id} ${pr_number} ${autofixcommentfile}
    else
        echo "CRA Auto remediation: Unsupported SCM type, could not post a comment to the PR"
    fi
  fi

  cd "$WORKSPACE" || exit 1
  set +x

}

is-repo-enabled-for-auto-remediation() {
  local repo=$1
  local enabled="false"

  local repos=$(get_env opt-in-cra-auto-remediation-enabled-repos "")
  # if this variable is not specified then assume that auto remediation is turned on for all repos
  if [ "${repos}" == "" ]; then
    enabled="true"
  fi 

  IFS=', ' read -r -a enabled_repos <<< "${repos}"
  for enabled_repo in "${enabled_repos[@]}"
  do
    if [ "${enabled_repo}" == "${repo}" ]; then
      enabled="true"
    fi 
  done

  echo ${enabled}
}

# This function checks if relevant files have been changed such as
# package.json and package-lock.json for nodejs
# build.gradle, gradle.lockfile, buildscript-gradle.lockfile for gradle
# pom.xml for maven
num-relevant-files-changed() {
  count=0

  # nodejs
  count=$(($(num-file-modified package.json) + ${count}))
  count=$(($(num-file-modified package-lock.json) + ${count}))

  # gradle
  count=$(($(num-file-modified build.gradle) + ${count}))
  count=$(($(num-file-modified gradle.lockfile) + ${count}))
  count=$(($(num-file-modified buildscript-gradle.lockfile) + ${count}))

  # maven
  count=$(($(num-file-modified pom.xml) + ${count}))

  echo ${count}
}

num-file-modified() {
  local filename=$1

  modified_count=$(git diff --name-only | grep "${filename}" | wc -l)
  echo ${modified_count}
}

packages-from-comment-file() {
  local comment_file=$1

  local package=""
  local i=12
  local comment=$(cat ${comment_file})
  local subcomment=$(echo $comment | awk -F'###' '{ print $2 }')
  if [ "${subcomment}" == " Top Level Packages Upgraded " ]; then
    echo ""
  else
    while [ "$package" != "Snyk ID" ]; do
        apackage=$(echo $subcomment | awk -F'\|' -v var=$i '{ print $var }')
        if [ "${apackage}" == " Snyk ID " ] || [ "${apackage}" == "" ]; then
            break
        fi
        if [ "$i" -eq "12" ]; then
            package=${apackage}
        else
            package=${package}", "${apackage}
        fi
        i=$[$i + 5]
    done
   fi
   echo $package
}

github-integrated-add-comment-to-pr() {
  local hostname=$1
  local owner=$2
  local repo=$3
  local pr_number=$4
  local comments_file=$5

  export token=$(cat "$WORKSPACE/auto-remediation-git-token")

  comment_text=$(cat ${comments_file})
  jq --arg metadata "${comment_text}" \
     '{"body": $metadata}' <<< {} > ./comment_payload.json

  curl \
    -X POST \
    -H "Accept: application/vnd.github.text+json" \
    -H "Authorization: Bearer ${token}"\
    "https://${hostname}/api/v3/repos/${owner}/${repo}/issues/${pr_number}/comments" \
    -s \
    -d @comment_payload.json 
}

github-integrated-create-pr() {
  local hostname=$1
  local owner=$2
  local repo=$3
  local source_branch=$4
  local target_branch=$5
  local comments_file=$6
  
  export token=$(cat "$WORKSPACE/auto-remediation-git-token")

  comment_text=$(cat ${comments_file})
  packages=$(packages-from-comment-file ${comments_file})
  jq --arg title "CRA auto remediation fix packages - ${packages}" \
     --arg body "${comment_text}" \
     --arg pr_head "${source_branch}" \
     --arg pr_base "${target_branch}" \
     '{"title": $title, "body": $body, "head": $pr_head, "base": $pr_base}' <<< {} > ./pr_payload.json

  curl \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    "https://${hostname}/api/v3/repos/${owner}/${repo}/pulls" \
    -s \
    -d @pr_payload.json 
}

github-integrated-get-existing-pr() {
  local hostname=$1
  local owner=$2
  local repo=$3
  local source_branch=$4
  local target_branch=$5

  export token=$(cat "$WORKSPACE/auto-remediation-git-token")

  curl \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    "https://${hostname}/api/v3/repos/${owner}/${repo}/pulls?state=open&head=${owner}:${source_branch}&base=${target_branch}" \
    -s \
    -o response.json

  pr_number=$(cat response.json | jq 'if . | length != 0 then .[0].number else 0 end')
  if [ "${pr_number}" -eq 0 ]; then
    echo "0"
  else
    echo $pr_number
  fi
}

git-get-default-branch() {
  gitremote=$(git remote)
  defaultbranch=$(git remote show ${gitremote} | sed -n '/HEAD branch/s/.*: //p')
  echo $defaultbranch
}

hostedgit-add-comment-to-mr() {
  local hostname=$1
  local project_id=$2
  local issue_iid=3
  local comments_file=$4

  export token=$(cat "$WORKSPACE/auto-remediation-git-token")

  comment_text=$(cat ${comments_file})
  jq --arg metadata "${comment_text}" \
     '{"body": $metadata}' <<< {} > ./comment_payload.json

  curl \
    -X POST \
    -H "Content-Type: application/json" \
    -H "PRIVATE-TOKEN: ${token}"\
    "https://${hostname}/api/v4/projects/${project_id}/merge_requests/${issue_iid}/notes" \
    -s \
    -d @comment_payload.json 
}

hostedgit-create-mr() {
  local hostname=$1
  local project_id=$2
  local comments_file=$3
  local source_branch=$4
  local target_branch=$5

  export token=$(cat "$WORKSPACE/auto-remediation-git-token")

  comment_text=$(cat ${comments_file})
  packages=$(packages-from-comment-file ${comment_text})
  jq --arg title "CRA auto remediation fix packages - ${packages}" \
     --arg body "${comment_text}" \
     --arg source "${source_branch}" \
     --arg target "${target_branch}" \
     '{"title": $title, "description": $body, "source_branch": $source, "target_branch": $target}' <<< {} > ./mr_payload.json

  echo "Creating a merge request"
  curl \
    -X POST \
    -H "Content-Type: application/json" \
    -H "PRIVATE-TOKEN: ${token}"\
    "https://${hostname}/api/v4/projects/${project_id}/merge_requests" \
    -s \
    -d @mr_payload.json 
}

hostedgit-get-existing-mr() {
  local hostname=$1
  local project_id=$2
  local source_branch=$3
  local target_branch=$4

  export token=$(cat "$WORKSPACE/auto-remediation-git-token")

  curl \
    -H "Content-Type: application/json" \
    -H "PRIVATE-TOKEN: ${token}"\
    "https://${hostname}/api/v4/projects/${project_id}/merge_requests?state=opened&source_branch=${source_branch}&target_branch=${target_branch}" \
    -s \
    -o response.json

  mr_number=$(cat response.json | jq 'if . | length != 0 then .[0].iid else 0 end')
  if [ -z "${mr_number}" ]; then
    echo "0"
  else
    echo $mr_number
  fi
}

hostedgit-get-project-id() {
  local hostname=$1
  local url=$2

  export token=$(cat "$WORKSPACE/auto-remediation-git-token")

  curl \
    -H "Content-Type: application/json" \
    -H "PRIVATE-TOKEN: ${token}"\
    "https://${hostname}/api/v4/projects" \
    -s \
    -o response.json
  
  project_id=$(cat response.json | jq --arg aurl "${url}" '.[] | select(.web_url | contains($aurl)) | .id')
  if [ -z "${project_id}" ]; then
    echo "0"
  else
    echo $project_id
  fi
}
